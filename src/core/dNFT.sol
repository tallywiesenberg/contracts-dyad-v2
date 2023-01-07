// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IAggregatorV3} from "../interfaces/AggregatorV3Interface.sol";
import {DYAD} from "./Dyad.sol";

contract dNFT is ERC721Enumerable, ReentrancyGuard {
  using SafeCast   for int256;
  using SafeCast   for uint256;
  using SignedMath for int256;
  using Counters   for Counters.Counter;

  // Minimum required to mint a new dNFT
  uint public immutable DEPOSIT_MINIMUM;

  // Maximum number of dNFTs that can exist simultaneously
  uint public immutable MAX_SUPPLY;

  // Minimum number of blocks required between sync calls
  uint public immutable BLOCKS_BETWEEN_SYNCS;

  // Minimum collaterization ratio required, for DYAD to be withdrawn
  uint public immutable MIN_COLLATERIZATION_RATIO; 

  // Maximum % of DYAD that can be minted by TVL 
  uint public immutable MAX_MINTED_BY_TVL; 

  // ETH price from the last sync call
  uint public lastEthPrice;

  // Number of dNFTs minted so far
  Counters.Counter public tokenIdCounter;

  // Last block, sync was called on
  uint public lastSyncedBlock;

  // Min/Max XP over all dNFTs
  uint public minXp; uint public maxXp;

  uint8[40] XP_TABLE = [51,  51,  51,  51,  52,  53,  53,  54,  55,
                        57,  58,  60,  63,  66,  69,  74,  79,  85,
                        92,  99,  108, 118, 128, 139, 150, 160, 171,
                        181, 191, 200, 207, 214, 220, 225, 230, 233,
                        236, 239, 241, 242];

  // dNFT id => dNFT
  mapping(uint => Nft) public idToNft;

  // dNFT id => Block that deposit was called on
  // Needed to avoid deposit + withdraw in the same block, which enables
  // different flash loan attacks.
  mapping(uint => uint) private _idToBlockOfLastDeposit;

  struct Nft {
    uint withdrawn;      // dyad withdrawn from the pool deposit
    int  deposit;        // dyad balance in pool
    uint xp;             // always positive, always inflationary
    bool isLiquidatable; // if true, anyone can liquidate the dNFT
  }

  // Convenient way to store output of internal `calcMulti` functions
  struct Multi  { uint   product ; uint xp; }
  struct Multis { uint[] products; uint productsSum; uint[] xps; }

  DYAD public dyad;
  IAggregatorV3 internal oracle;

  enum Mode { 
    BURNING, // Price of ETH went down
    MINTING  // Price of ETH went up
  }

  event NftMinted    (address indexed to, uint indexed id);
  event DyadMinted   (address indexed to, uint indexed id, uint amount);
  event DyadWithdrawn(address indexed to, uint indexed id, uint amount);
  event DyadDeposited(address indexed to, uint indexed id, uint amount);
  event DyadRedeemed (address indexed to, uint indexed id, uint amount);
  event DyadMoved    (uint    indexed from, uint    indexed to, uint amount);
  event NftLiquidated(address indexed from, address indexed to, uint indexed id);
  event Synced       (uint id);

  error ReachedMaxSupply       ();
  error NoEthSupplied          ();
  error SyncedTooRecently      ();
  error ExceedsAverageTVL      ();
  error NotNFTOwner            (uint id);
  error NotLiquidatable        (uint id);
  error CrTooLow               (uint cr);
  error AmountZero             (uint amount);
  error NotReachedMinAmount    (uint amount);
  error ExceedsWithdrawalLimit (uint amount);
  error ExceedsDepositLimit    (uint amount);
  error AddressZero            (address addr);
  error FailedDyadTransfer     (address to, uint amount);
  error FailedEthTransfer      (address to, uint amount);
  error XpOutOfRange           (uint xp);
  error CannotMoveDepositToSelf(uint from, uint to, uint amount);
  error MinXpHigherThanMaxXp   (uint minXp, uint maxXp);
  error CannotDepositAndWithdrawInSameBlock();

  modifier onlyNFTOwner(uint id) {
    if (ownerOf(id) != msg.sender) revert NotNFTOwner(id); _;
  }
  modifier amountNotZero(uint amount) {
    if (amount == 0) revert AmountZero(amount); _;
  }
  modifier addressNotZero(address addr) {
    if (addr == address(0)) revert AddressZero(addr); _;
  }

  constructor(
    address          _dyad,
    uint             _depositMinimum,
    uint             _maxSupply, 
    uint             _blocksBetweenSyncs,
    uint             _minCollaterizationRatio,
    uint             _maxMintedByTVL,
    address          _oracle, 
    address[] memory _insiders
  ) ERC721("DYAD NFT", "dNFT") {
    dyad                      = DYAD(_dyad);
    oracle                    = IAggregatorV3(_oracle);
    lastEthPrice              = _getLatestEthPrice();
    DEPOSIT_MINIMUM           = _depositMinimum;
    MAX_SUPPLY                = _maxSupply;
    BLOCKS_BETWEEN_SYNCS      = _blocksBetweenSyncs;
    MIN_COLLATERIZATION_RATIO = _minCollaterizationRatio;
    MAX_MINTED_BY_TVL         = _maxMintedByTVL;
    minXp                     = _maxSupply;
    maxXp                     = _maxSupply << 1; // *2

    for (uint i = 0; i < _insiders.length; i++) { _mintNft(_insiders[i]); }
  }

  // ETH price in USD
  function _getLatestEthPrice() internal view returns (uint) {
    ( , int newEthPrice, , , ) = oracle.latestRoundData();
    return newEthPrice.toUint256();
  }

  // Mint new dNFT to `to` with a deposit of atleast `DEPOSIT_MINIMUM`
  function mintNft(address to) external addressNotZero(to) payable returns (uint) {
    uint id = _mintNft(to);
    _mintDyad(id, DEPOSIT_MINIMUM);
    uint xp = idToNft[id].xp;
    if (xp < minXp) { minXp = xp; } // sync could have increased `minXp`
    return id;
  }

  // Mint new nft to `to` with the same xp and withdrawn amount as `nft`
  function _mintCopy(
      address to,
      Nft memory nft
  ) internal returns (uint) { 
      uint id = _mintNft(to);
      Nft storage newNft = idToNft[id];
      uint minDeposit;
      if (nft.deposit < 0) { minDeposit = nft.deposit.abs(); }
      uint amount = _mintDyad(id, minDeposit);
      newNft.deposit   = amount.toInt256() + nft.deposit;
      newNft.xp        = nft.xp;
      newNft.withdrawn = nft.withdrawn;
      return id;
  }

  // Mint new dNFT to `to`
  function _mintNft(address to) private returns (uint id) {
    if (totalSupply() >= MAX_SUPPLY) { revert ReachedMaxSupply(); }
    id = tokenIdCounter.current();
    tokenIdCounter.increment();
    _mint(to, id); 
    Nft storage nft = idToNft[id];
    nft.xp = (MAX_SUPPLY<<1) - (totalSupply()-1); // break xp symmetry
    emit NftMinted(to, id);
  }

  // Mint and deposit DYAD into dNFT
  function mintDyad(
      uint id
  ) payable public onlyNFTOwner(id) returns (uint amount) {
      amount = _mintDyad(id, 0);
  }

  // Mint at least `minAmount` of DYAD to dNFT 
  function _mintDyad(
      uint id,
      uint minAmount
  ) private returns (uint) {
      if (msg.value == 0) { revert NoEthSupplied(); }
      uint newDyad = _getLatestEthPrice() * msg.value/100000000;
      if (newDyad == 0)        { revert AmountZero(newDyad); }
      if (newDyad < minAmount) { revert NotReachedMinAmount(newDyad); }
      dyad.mint(address(this), newDyad);
      idToNft[id].deposit += newDyad.toInt256();
      emit DyadMinted(msg.sender, id, newDyad);
      return newDyad;
  }

  // Deposit `amount` of DYAD into dNFT
  function deposit(
      uint id, 
      uint amount
  ) external amountNotZero(amount) returns (uint) {
      _idToBlockOfLastDeposit[id] = block.number;
      Nft storage nft = idToNft[id];
      if (amount > nft.withdrawn) { revert ExceedsWithdrawalLimit(amount); }
      nft.deposit   += amount.toInt256();
      nft.withdrawn -= amount;
      bool success = dyad.transferFrom(msg.sender, address(this), amount);
      if (!success) { revert FailedDyadTransfer(address(this), amount); }
      emit DyadDeposited(msg.sender, id, amount);
      return amount;
  }

  // Withdraw `amount` of DYAD from dNFT
  function withdraw(
      uint id,
      uint amount
  ) external onlyNFTOwner(id) amountNotZero(amount) returns (uint) {
      if (_idToBlockOfLastDeposit[id] == block.number) { revert CannotDepositAndWithdrawInSameBlock(); }
      Nft storage nft = idToNft[id];
      if (amount.toInt256() > nft.deposit) { revert ExceedsDepositLimit(amount); }
      uint updatedBalance  = dyad.balanceOf(address(this)) - amount;
      uint totalWithdrawn  = dyad.totalSupply() - updatedBalance;
      uint cr =  updatedBalance*10000 / totalWithdrawn;      
      if (cr < MIN_COLLATERIZATION_RATIO) { revert CrTooLow(cr); }
      uint newWithdrawn = nft.withdrawn + amount;
      uint averageTVL   = dyad.balanceOf(address(this)) / totalSupply();
      if (newWithdrawn > averageTVL) { revert ExceedsAverageTVL(); }
      nft.withdrawn  = newWithdrawn;
      nft.deposit   -= amount.toInt256();
      bool success = dyad.transfer(msg.sender, amount);
      if (!success) { revert FailedDyadTransfer(msg.sender, amount); }
      emit DyadWithdrawn(msg.sender, id, amount);
      return amount;
  }

  // Redeem `amount` of DYAD for ETH from dNFT
  function redeem(
      uint id,
      uint amount
  ) external nonReentrant() onlyNFTOwner(id) amountNotZero(amount) returns (uint) {
      Nft storage nft = idToNft[id];
      if (amount > nft.withdrawn) { revert ExceedsWithdrawalLimit(amount); }
      nft.withdrawn -= amount;
      dyad.burn(msg.sender, amount);
      uint eth = amount*100000000 / lastEthPrice;
      (bool success, ) = payable(msg.sender).call{value: eth}("");
      if (!success) { revert FailedEthTransfer(msg.sender, eth); }
      emit DyadRedeemed(msg.sender, id, amount);
      return eth;
  }

  // Move `amount` `from` one dNFT deposit `to` another dNFT deposit
  function moveDeposit(
      uint _from,
      uint _to,
      uint amount
  ) external onlyNFTOwner(_from) amountNotZero(amount) returns (uint) {
      if (_from == _to) { revert CannotMoveDepositToSelf(_from, _to, amount); }
      Nft storage from = idToNft[_from];
      if (amount.toInt256() > from.deposit) { revert ExceedsDepositLimit(amount); }
      Nft storage to   = idToNft[_to];
      from.deposit    -= amount.toInt256();
      to.deposit      += amount.toInt256();
      emit DyadMoved(_from, _to, amount);
      return amount;
  }

  // Liquidate dNFT by burning it and minting a new copy to `to`
  function liquidate(
      uint id,
      address to
  ) external addressNotZero(to) payable returns (uint) {
      Nft memory nft = idToNft[id];
      if (!nft.isLiquidatable) { revert NotLiquidatable(id); }
      emit NftLiquidated(ownerOf(id), to,  id); 
      _burn(id); 
      delete idToNft[id];
      return _mintCopy(to, nft);
  }

  // Sync by minting/burning DYAD to keep the peg and update each dNFT.
  // dNFT with `id` gets a boost.
  function sync(uint id) public returns (uint) {
    if (block.number < lastSyncedBlock + BLOCKS_BETWEEN_SYNCS) { 
      revert SyncedTooRecently(); 
    }

    lastSyncedBlock  = block.number;
    uint newEthPrice = _getLatestEthPrice();
    Mode mode        = newEthPrice > lastEthPrice ? Mode.MINTING 
                                                  : Mode.BURNING;
 
    uint ethPriceDelta = newEthPrice*10000 / lastEthPrice; 
    // get `ethPriceDelta` in basis points
    mode == Mode.BURNING ? ethPriceDelta  = 10000 - ethPriceDelta 
                         : ethPriceDelta -= 10000;

    uint dyadDelta = _updateNFTs(ethPriceDelta, mode, id);

    if (dyadDelta > 0) {
      mode == Mode.MINTING ? dyad.mint(address(this), dyadDelta) 
                           : dyad.burn(address(this), dyadDelta);
    }

    lastEthPrice = newEthPrice;

    emit Synced(id);
    return dyadDelta;
  }

  function _updateNFTs(
      uint ethPriceDelta,
      Mode mode,
      uint id
  ) private returns (uint) {
      Multis memory multis = _calcMultis(mode, id);
      uint dyadDelta       = _percentageOf(dyad.totalSupply(), ethPriceDelta);
      uint _minXp          = type(uint256).max; // local min
      uint _maxXp          = maxXp;             // local max
      uint productsSum     = multis.productsSum;
      if (productsSum == 0) { productsSum = 1; } // to avoid dividing by 0 
      uint totalSupply     = totalSupply();

      for (uint i = 0; i < totalSupply; ) {
        uint tokenId           = tokenByIndex(i);
        uint relativeMulti     = multis.products[i]*10000 / productsSum;
        uint relativeDyadDelta = _percentageOf(dyadDelta, relativeMulti);
        Nft storage nft = idToNft[tokenId];

        if (mode == Mode.BURNING) {
          if (nft.deposit > 0) {
            uint xpAccrual     = relativeDyadDelta*100 / (multis.xps[i]);
            if (id == tokenId) { xpAccrual = xpAccrual << 1; } // boost by *2
            nft.xp            += xpAccrual / (10**18);         // norm by 18 decimals
          }
          nft.deposit         -= relativeDyadDelta.toInt256();
        } else {
          nft.deposit         += relativeDyadDelta.toInt256();
        }

        nft.deposit > 0 ? nft.isLiquidatable = false : nft.isLiquidatable = true;
        if (nft.xp < _minXp) { _minXp = nft.xp; } // new local min
        if (nft.xp > _maxXp) { _maxXp = nft.xp; } // new local max
        unchecked { ++i; }
      }

      if (_minXp > _maxXp) { revert MinXpHigherThanMaxXp(_minXp, _maxXp); }
      minXp = _minXp; // save new min
      maxXp = _maxXp; // save new max
      return dyadDelta;
  }

  function _calcMultis(
      Mode mode,
      uint id
  ) private view returns (Multis memory) {
      uint nftTotalSupply    = totalSupply();
      uint dyadTotalSupply   = dyad.totalSupply();
      uint productsSum;
      uint[] memory products = new uint[](nftTotalSupply);
      uint[] memory xps      = new uint[](nftTotalSupply);

      for (uint i = 0; i < nftTotalSupply; ) {
        uint tokenId = tokenByIndex(i);
        Nft   memory nft   = idToNft[tokenId];
        Multi memory multi = _calcMulti(mode, nft, nftTotalSupply, dyadTotalSupply);

        if (id == tokenId && mode == Mode.MINTING) { 
          multi.product += _percentageOf(multi.product, 1500); // boost by 15%
        }

        products[i]  = multi.product;
        productsSum += multi.product;
        xps[i]       = multi.xp;
        unchecked { ++i; }
      }

      return Multis(products, productsSum, xps);
  }

  function _calcMulti(
      Mode mode,
      Nft memory nft,
      uint nftTotalSupply,
      uint dyadTotalSupply
  ) private view returns (Multi memory) {
      uint multiProduct; uint xpMulti;     

      if (nft.deposit > 0) {
        uint xpDelta       = maxXp - minXp;
        if (xpDelta == 0)  { xpDelta = 1; } // avoid division by 0
        uint xpScaled      = (nft.xp-minXp)*10000 / xpDelta;
        uint _deposit;
        if (nft.deposit > 0) { _deposit = nft.deposit.toUint256(); }
        uint mintedByNft     = nft.withdrawn + _deposit;
        uint avgTvl          = dyadTotalSupply   / nftTotalSupply;
        uint mintedByTvl     = mintedByNft*10000 / avgTvl;
        if (mode == Mode.BURNING && mintedByTvl > MAX_MINTED_BY_TVL) { 
          mintedByTvl = MAX_MINTED_BY_TVL;
        }
        xpMulti = _xpToMulti(xpScaled/100);
        if (mode == Mode.BURNING) { xpMulti = 300-xpMulti; } 
        uint depositMulti = (_deposit*10000) / (mintedByNft+1);
        multiProduct      = xpMulti * (mode == Mode.BURNING 
                            ? mintedByTvl 
                            : depositMulti);
      }

      return Multi(multiProduct, xpMulti);
  }

  // ----------------------- UTILS -----------------------
  function _percentageOf(
    uint x,
    uint basisPoints
  ) private pure returns (uint) { return x*basisPoints/10000; }

  // maps xp to a multiplier
  function _xpToMulti(uint xp) private view returns (uint) {
    if (xp < 0 || xp > 100) { revert XpOutOfRange(xp); }

    // - xp from 0 to 60 maps to 50, so we do not have to store it in the XP_TABLE
    // - if xp is over 60, we have to subtract 60+1 from it to get the correct index
    if (xp <= 60) { return 50; } else { return XP_TABLE[xp - 60 - 1]; }
  }
}
