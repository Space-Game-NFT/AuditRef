// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import "./interfaces/IMnAGame.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/ITraits.sol";
import "./interfaces/IORES.sol";
import "./interfaces/IMnA.sol";
import "./interfaces/ISpidox.sol";


contract MnAGameCR is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, IMnAGame {

  event MintCommitted(address indexed owner, uint256 indexed amount);
  event MintRevealed(address indexed owner, uint256 indexed amount);

  struct MintCommit {
    bool stake;
    uint16 amount;
  }

  uint256 public treasureChestTypeId;
  // max $ORES cost 
  uint256 private maxOresCost;

  // address -> commit # -> commits
  mapping(address => mapping(uint16 => MintCommit)) private _mintCommits;
  // address -> commit num of commit need revealed for account
  mapping(address => uint16) private _pendingCommitId;
  // commit # -> offchain random
  mapping(uint16 => uint256) private _commitRandoms;
  uint16 private _commitId;
  uint16 private pendingMintAmt;
  bool public allowCommits;

  // address => can call addCommitRandom
  mapping(address => bool) private admins;

  // reference to the Tower for choosing random Alien thieves
  IStakingPool public stakingPool;
  // reference to $ORES for burning on mint
  IORES public oresToken;
  // reference to Traits
  ITraits public traits;
  // reference to NFT collection
  IMnA public mnaNFT;
  // reference to spidox collection
  ISpidox public spidox;

  function initialize() initializer public {
    __Pausable_init_unchained();
    __ReentrancyGuard_init_unchained();
    __Ownable_init_unchained();
    _pause();
    maxOresCost = 90000 ether;
    _commitId = 1;
    allowCommits = true;
  }  

function _authorizeUpgrade(address) internal override onlyOwner {}

  /** CRITICAL TO SETUP */

  modifier requireContractsSet() {
      require(address(oresToken) != address(0) && address(traits) != address(0) 
        && address(mnaNFT) != address(0) && address(stakingPool) != address(0)
        , "Contracts not set");
      _;
  }

  function setContracts(address _ores, address _traits, address _wnd, address _stakingPool, address _spidox) external onlyOwner {
    oresToken = IORES(_ores);
    traits = ITraits(_traits);
    mnaNFT = IMnA(_wnd);
    stakingPool = IStakingPool(_stakingPool);
    spidox = ISpidox(_spidox);
  }

  /** EXTERNAL */

  function getPendingMint(address addr) external view returns (MintCommit memory) {
    require(_pendingCommitId[addr] != 0, "no pending commits");
    return _mintCommits[addr][_pendingCommitId[addr]];
  }

  function hasMintPending(address addr) external view returns (bool) {
    return _pendingCommitId[addr] != 0;
  }

  function canMint(address addr) external view returns (bool) {
    return _pendingCommitId[addr] != 0 && _commitRandoms[_pendingCommitId[addr]] > 0;
  }

  // Seed the current commit id so that pending commits can be revealed
  function addCommitRandom(uint256 seed) external {
    require(owner() == _msgSender() || admins[_msgSender()], "Only admins can call this");
    _commitRandoms[_commitId] = seed;
    _commitId += 1;
  }

  function deleteCommit(address addr) external {
    require(owner() == _msgSender() || admins[_msgSender()], "Only admins can call this");
    uint16 commitIdCur = _pendingCommitId[_msgSender()];
    require(commitIdCur > 0, "No pending commit");
    delete _mintCommits[addr][commitIdCur];
    delete _pendingCommitId[addr];
  }

  function forceRevealCommit(address addr) external {
    require(owner() == _msgSender() || admins[_msgSender()], "Only admins can call this");
    reveal(addr);
  }

  /** Initiate the start of a mint. This action burns $ORES, as the intent of committing is that you cannot back out once you've started.
    * This will add users into the pending queue, to be revealed after a random seed is generated and assigned to the commit id this
    * commit was added to. */
  function mintCommit(uint256 amount, bool stake) external whenNotPaused nonReentrant {
    require(allowCommits, "adding commits disallowed");
    require(tx.origin == _msgSender(), "Only EOA");
    require(_pendingCommitId[_msgSender()] == 0, "Already have pending mints");
    uint16 minted = mnaNFT.minted();
    uint256 maxTokens = mnaNFT.getMaxTokens();
    require(minted + pendingMintAmt + amount <= maxTokens, "All tokens minted");
    require(amount > 0 && amount <= 10, "Invalid mint amount");

    uint256 totalORESCost = 0;
    // Loop through the amount of 
    for (uint i = 1; i <= amount; i++) {
      totalORESCost += mintCost(minted + pendingMintAmt + i);
    }
    if (totalORESCost > 0) {
      oresToken.burn(_msgSender(), totalORESCost);
      oresToken.updateOriginAccess();
    }
    uint16 amt = uint16(amount);
    _mintCommits[_msgSender()][_commitId] = MintCommit(stake, amt);
    _pendingCommitId[_msgSender()] = _commitId;
    pendingMintAmt += amt;
    emit MintCommitted(_msgSender(), amount);
  }

  /** Reveal the commits for this user. This will be when the user gets their NFT, and can only be done when the commit id that
    * the user is pending for has been assigned a random seed. */
  function mintReveal() external whenNotPaused nonReentrant {
    require(tx.origin == _msgSender(), "Only EOA1");
    reveal(_msgSender());
  }

  function reveal(address addr) internal {
    uint16 commitIdCur = _pendingCommitId[addr];
    require(commitIdCur > 0, "No pending commit");
    require(_commitRandoms[commitIdCur] > 0, "random seed not set");
    uint16 minted = mnaNFT.minted();
    MintCommit memory commit = _mintCommits[addr][commitIdCur];
    pendingMintAmt -= commit.amount;
    uint16[] memory tokenIds = new uint16[](commit.amount);
    uint16[] memory tokenIdsToStake = new uint16[](commit.amount);
    uint256 seed = _commitRandoms[commitIdCur];
    for (uint k = 0; k < commit.amount; k++) {
      minted++;
      // scramble the random so the steal / treasure mechanic are different per mint
      seed = uint256(keccak256(abi.encode(seed, addr)));
      address recipient = selectRecipient(seed);
      if(recipient != addr && address(spidox) != address(0) && spidox.balanceOf(addr) > 0) {
        // If the mint is going to be stolen, there's a 50% chance 
        //  a alien will prefer a treasure chest over it
        if(seed & 1 == 1) {
          spidox.safeTransferFrom(addr, recipient, spidox.tokenOfOwnerByIndex(addr, 0), "");
          recipient = addr;
        }
      }
      tokenIds[k] = minted;
      if (!commit.stake || recipient != addr) {
        mnaNFT.mint(recipient, seed);
      } else {
        mnaNFT.mint(address(stakingPool), seed);
        tokenIdsToStake[k] = minted;
      }
    }
    mnaNFT.updateOriginAccess(tokenIds);
    if(commit.stake) {
      stakingPool.addManyToMarinePoolAndAlienPool(addr, tokenIdsToStake);
    }
    delete _mintCommits[addr][commitIdCur];
    delete _pendingCommitId[addr];
    emit MintCommitted(addr, tokenIds.length);
  }

  /** 
   * @param tokenId the ID to check the cost of to mint
   * @return the cost of the given token ID
   */
  function mintCost(uint256 tokenId) public view returns (uint256) {
    if (tokenId <= 6969) return 0 ether;
    if (tokenId <= 14000) return 30000 ether;
    if (tokenId <= 21000) return 60000 ether;
    if (tokenId <= 28000) return 90000 ether;
    return maxOresCost;
  }

  /**
   * the first 25% (ETH purchases) go to the minter
   * the remaining 80% have a 10% chance to be given to a random staked alien
   * @param seed a random value to select a recipient from
   * @return the address of the recipient (either the minter or the Alien thief's owner)
   */
  function selectRecipient(uint256 seed) internal view returns (address) {
    if (((seed >> 245) % 5) != 0) return _msgSender(); // top 10 bits haven't been used
    address thief = stakingPool.randomAlienOwner(seed >> 144); // 144 bits reserved for trait selection
    if (thief == address(0x0)) return _msgSender();
    return thief;
  }

  /** ADMIN */

  /**
   * enables owner to pause / unpause contract
   */
  function setPaused(bool _paused) external requireContractsSet onlyOwner {
    if (_paused) _pause();
    else _unpause();
  }

  function setMaxOresCost(uint256 _amount) external requireContractsSet onlyOwner {
    maxOresCost = _amount;
  } 

  function setTreasureChestId(uint256 typeId) external onlyOwner {
    treasureChestTypeId = typeId;
  }

  function setAllowCommits(bool allowed) external onlyOwner {
    allowCommits = allowed;
  }

  /** Allow the contract owner to set the pending mint amount.
    * This allows any long-standing pending commits to be overwritten, say for instance if the max supply has been 
    *  reached but there are many stale pending commits, it could be used to free up those spaces if needed/desired by the community.
    * This function should not be called lightly, this will have negative consequences on the game. */
  function setPendingMintAmt(uint256 pendingAmt) external onlyOwner {
    pendingMintAmt = uint16(pendingAmt);
  }

  /**
  * enables an address to mint / burn
  * @param addr the address to enable
  */
  function addAdmin(address addr) external onlyOwner {
      admins[addr] = true;
  }

  /**
  * disables an address from minting / burning
  * @param addr the address to disbale
  */
  function removeAdmin(address addr) external onlyOwner {
      admins[addr] = false;
  }

  /**
   * allows owner to withdraw funds from minting
   */
  function withdraw() external onlyOwner {
    payable(owner()).transfer(address(this).balance);
  }
}