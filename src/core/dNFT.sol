// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {DYAD} from "./dyad.sol";
import {Pool} from "./Pool.sol";

struct Nft {
  uint withdrawn; // dyad withdrawn from the pool deposit
  int deposit;    // dyad balance in pool
  uint xp;        // always positive, always inflationary
}

contract dNFT is ERC721Enumerable, ERC721Burnable {
  // maximum number of nfts that can exist at one point in time
  uint constant public MAX_SUPPLY = 300;

  // 150% in basis points
  uint constant public MAX_COLLATERATION_RATIO = 15000; 

  // stores the number of nfts that have been minted. we need this in order to
  // generate a new id for the next minted nft.
  uint public numberOfMints;

  // deposit minimum required to mint a new dnft
  // should be a constant, but then some of the tests do not work because they 
  // depend on manipulating this value.
  // as this is only set in the constructor, it should not be a problem.
  uint public DEPOSIT_MINIMUM;

  // here we store the min/max value of xp over every dNFT,
  // which allows us to do a normalization, without iterating over
  // all of them to find the min/max value.
  uint public MIN_XP = 300;

  // after minting the first nft this will be the MAX_XP. After that it will
  // be updated by the `sync` in the pool contract.
  uint public MAX_XP = MIN_XP + MAX_SUPPLY;

  DYAD public dyad;
  Pool public pool;

  // mapping from nft id to nft data
  mapping(uint => Nft) public idToNft;

  event NftMinted    (address indexed to, uint indexed id);
  event DyadMinted   (address indexed to, uint indexed id, uint amount);
  event DyadWithdrawn(address indexed to, uint indexed id, uint amount);
  event DyadDeposited(address indexed to, uint indexed id, uint amount);
  event DyadRedeemed (address indexed to, uint indexed id, uint amount);

  modifier onlyNFTOwner(uint id) {
    require(this.ownerOf(id) == msg.sender, "dNFT: Only callable by NFT owner");
    _;
  }

  modifier onlyPool() {
    require(address(pool) == msg.sender, "dNFT: Only callable by Pool contract");
    _;
  }

  constructor(address _dyad,
              uint _depositMinimum,
              address[] memory insiders) ERC721("DYAD NFT", "dNFT") {
    dyad            = DYAD(_dyad);
    DEPOSIT_MINIMUM = _depositMinimum;

    for (uint i = 0; i < insiders.length; i++) { _mintNft(insiders[i]); }
  }

  function setPool(address newPool) public {
    // can only be set once
    require(address(pool) == address(0),"dNFT: Pool is already set");
    pool = Pool(newPool);
  }

  // The following functions are overrides required by Solidity.
  function _beforeTokenTransfer(address from,
                                address to,
                                uint256 tokenId,
                                uint256 batchSize)
      internal override(ERC721, ERC721Enumerable)
  { super._beforeTokenTransfer(from, to, tokenId, batchSize); }

  // The following functions are overrides required by Solidity.
  function supportsInterface(bytes4 interfaceId)
      public
      view
      override(ERC721, ERC721Enumerable)
      returns (bool)
  { return super.supportsInterface(interfaceId); }

  function updateXP(uint _minXP, uint _maxXP) external onlyPool {
    if (_minXP < MIN_XP) { MIN_XP = _minXP; }
    if (_maxXP > MAX_XP) { MAX_XP = _maxXP; }
  }

  function updateNft(uint id, Nft memory nft) external onlyPool {
    idToNft[id] = nft;
  }

  // VERY IMPORTANT: we add the pool here so we can burn any dnft. 
  // This is needed to make the liquidation mechanism work.
  function _isApprovedOrOwner(address spender,
                              uint256 tokenId) 
                              internal override view virtual returns (bool) {
    address owner = ERC721.ownerOf(tokenId);
    return (spender == address(pool) || // <- only change
            spender == owner ||
            isApprovedForAll(owner, spender) ||
            getApproved(tokenId) == spender);
  }

  // to mint a new dnft a msg.value of 'depositMinimum' USD denominated in ETH
  // is required.
  function mintNft(address receiver) external payable returns (uint) {
    uint id = _mintNft(receiver);
    _mintDyad(id, DEPOSIT_MINIMUM);
    return id;
  }

  // Mint a new nft that will have the same xp and withdrawn amount as `nft`.
  // The deposit of the newly minted nft depends on `msg.value`.
  function mintNftCopy(address receiver,
                       Nft memory nft,
                       uint _depositMinimum) external payable onlyPool returns (uint) {
    uint id = _mintNft(receiver);
    Nft storage newNft = idToNft[id];
    // copy over xp and withdrawn. deposit is handled by _mintDyad below.
    newNft.xp        = nft.xp;
    newNft.withdrawn = nft.withdrawn;

    // mint the required dyad to cover the negative deposit. updates the deposit
    // accordingly.
    _mintDyad(id, _depositMinimum); 
    return id;
  }

  // the main reason for this method is that we need to be able to mint
  // nfts for the core team and investors without the deposit minimum,
  // this happens in the constructor where we call this method directly.
  function _mintNft(address receiver) private returns (uint id) {
    // we can not use totalSupply() for the id because of the liquidation
    // mechanism, which burns and creates new nfts. This way ensures that we
    // alway use a new id.
    id = numberOfMints;
    require(totalSupply() < MAX_SUPPLY, "Max supply reached");
    _mint(receiver, id); 
    numberOfMints += 1;

    Nft storage nft = idToNft[id];

    // add MIN_XP to the nft to start with
    // We do MAX_SUPPLY - totalSupply() not to incentivice something but to
    // break the xp symmetry.
    // +1 to compensate for the newly minted nft which increments totalSupply()
    // by 1.
    nft.xp = MIN_XP + MAX_SUPPLY-totalSupply()+1;

    // the new nft.xp could potentially be a new xp minimum!
    if (nft.xp < MIN_XP) { MIN_XP = nft.xp; }
    emit NftMinted(receiver, id);
  }

  // mint new DYAD and deposit it in the pool
  function mintDyad(uint id) payable public onlyNFTOwner(id) returns (uint amount) {
    amount = _mintDyad(id, 0);
  }

  function _mintDyad(uint id, uint minAmount) private returns (uint amount) {
    require(msg.value > 0, "You need to send some ETH to mint dyad");
    amount = pool.mintDyad{value: msg.value}(minAmount);
    dyad.approve(address(pool), amount);
    pool.deposit(amount);
    idToNft[id].deposit += int(amount);
    emit DyadMinted(msg.sender, id, amount);
  }

  // withdraw dyad from the pool to msg.sender
  function withdraw(uint id, uint amount) external onlyNFTOwner(id) {
    uint poolDyadBalance = dyad.balanceOf(address(pool));
    uint cr = (dyad.totalSupply() - poolDyadBalance) * 10000 / poolDyadBalance;
    require(cr < MAX_COLLATERATION_RATIO, "CR is over 150%"); 

    Nft storage nft = idToNft[id];
    require(int(amount) <= nft.deposit, "dNFT: Withdraw amount exceeds deposit");
    nft.deposit   -= int(amount);
    nft.withdrawn += amount;
    pool.withdraw(msg.sender, amount);
    emit DyadWithdrawn(msg.sender, id, amount);
  }

  // deposit dyad back into the pool
  function deposit(uint id, uint amount) external {
    Nft storage nft = idToNft[id];
    // The amount you want to deposit is higher than the amount you have 
    // withdrawn
    require(amount <= nft.withdrawn, "dNFT: Deposit exceeds withdrawn");

    nft.deposit   += int(amount);
    nft.withdrawn -= amount;

    // transfer dyad to the nft
    // approve the pool to spend the dyad of this contract
    // deposit dyad in the pool
    dyad.transferFrom(msg.sender, address(this), amount);
    dyad.approve(address(pool), amount);
    pool.deposit(amount);

    emit DyadDeposited(msg.sender, id, amount);
  }

  // redeem DYAD for ETH
  function redeem(uint id, uint amount) external onlyNFTOwner(id) returns (uint usdInEth) {
    Nft storage nft = idToNft[id];
    require(amount <= nft.withdrawn, "dNFT: Amount to redeem exceeds withdrawn");
    nft.withdrawn -= amount;
    dyad.transferFrom(msg.sender, address(pool), amount);
    usdInEth = pool.redeem(msg.sender, amount);
    emit DyadRedeemed(msg.sender, id, amount);
    return usdInEth;
  }
}
