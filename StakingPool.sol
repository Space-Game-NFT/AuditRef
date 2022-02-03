// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IMnAGame.sol";
import "./interfaces/IMnA.sol";
import "./interfaces/IORES.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/IRandomSeedGenerator.sol";

contract StakingPool is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IERC721Receiver, PausableUpgradeable, IStakingPool {
  
  // maximum rank for a Marine/Alien
  uint8 public constant MAX_RANK = 4;

  // struct to store a stake's token, owner, and earning values
  struct Stake {
    uint16 tokenId;
    uint80 value;
    address owner;
  }

  uint256 private totalRankStaked;
  uint256 private numMarinesStaked;

  event TokenStaked(address indexed owner, uint256 indexed tokenId, bool indexed isMarine, uint256 value);
  event MarineClaimed(uint256 indexed tokenId, bool indexed unstaked, uint256 earned);
  event AlienClaimed(uint256 indexed tokenId, bool indexed unstaked, uint256 earned);

  // reference to the MnA NFT contract
  IMnA public mnaNFT;
  // reference to the MnA NFT contract
  IMnAGame public mnaGame;
  // reference to the $ORES contract for minting $ORES earnings
  IORES public oresToken;
  // reference to Randomer 
  IRandomSeedGenerator public randomSeedGenerator;

  // maps tokenId to stake
  mapping(uint256 => Stake) private marinePool; 
  // maps rank to all Alien staked with that rank
  mapping(uint256 => Stake[]) private alienPool; 
  // tracks location of each Alien in AlienPool
  mapping(uint256 => uint256) private alienPoolIndices; 
  // any rewards distributed when no aliens are staked
  uint256 private unaccountedRewards; 
  // amount of $ORES due for each rank point staked
  uint256 private oresPerRank; 

  // marines earn 10000 $ORES per day
  uint256 public constant DAILY_ORES_RATE = 10000 ether;
  // marines must have 2 days worth of $ORES to unstake or else they're still guarding the marine pool
  uint256 public constant MINIMUM_TO_EXIT = 2 days;
  // aliens take a 20% tax on all $ORES claimed
  uint256 public constant ORES_CLAIM_TAX_PERCENTAGE = 20;
  // there will only ever be (roughly) 2 billion $ORES earned through staking
  uint256 public constant MAXIMUM_GLOBAL_ORES = 2000000000 ether;
  uint256 public treasureChestTypeId;

  // amount of $ORES earned so far
  uint256 public totalORESEarned;
  // the last time $ORES was claimed
  uint256 private lastClaimTimestamp;

  // emergency rescue to allow unstaking without any checks but without $ORES
  bool public rescueEnabled;

  function initialize() initializer public {
    __Pausable_init_unchained();
    __ReentrancyGuard_init_unchained();
    __Ownable_init_unchained();
    _pause();
  }  

function _authorizeUpgrade(address) internal override onlyOwner {}

  /** CRITICAL TO SETUP */

  modifier requireContractsSet() {
      require(address(mnaNFT) != address(0) && address(oresToken) != address(0) 
        && address(mnaGame) != address(0) && address(randomSeedGenerator) != address(0), "Contracts not set");
      _;
  }

  function setContracts(address _mnaNFT, address _gp, address _mnaGame, address _rand) external onlyOwner {
    mnaNFT = IMnA(_mnaNFT);
    oresToken = IORES(_gp);
    mnaGame = IMnAGame(_mnaGame);
    randomSeedGenerator = IRandomSeedGenerator(_rand);
  }

  function setTreasureChestId(uint256 typeId) external onlyOwner {
    treasureChestTypeId = typeId;
  }

  /** STAKING */

  /**
   * adds Marines and Aliens to the MarinePool and AlienPool
   * @param account the address of the staker
   * @param tokenIds the IDs of the Marines and Aliens to stake
   */
  function addManyToMarinePoolAndAlienPool(address account, uint16[] calldata tokenIds) external override nonReentrant {
    require(tx.origin == _msgSender() || _msgSender() == address(mnaGame), "Only EOA");
    require(account == tx.origin, "account to sender mismatch");
    for (uint i = 0; i < tokenIds.length; i++) {
      if (_msgSender() != address(mnaGame)) { // dont do this step if its a mint + stake
        require(mnaNFT.ownerOf(tokenIds[i]) == _msgSender(), "You don't own this token");
        mnaNFT.transferFrom(_msgSender(), address(this), tokenIds[i]);
      } else if (tokenIds[i] == 0) {
        continue; // there may be gaps in the array for stolen tokens
      }

      if (mnaNFT.isMarine(tokenIds[i])) 
        _addMarineToMarinePool(account, tokenIds[i]);
      else 
        _addAlienToAlienPool(account, tokenIds[i]);
    }
  }

  /**
   * adds a single Marine to the MarinePool
   * @param account the address of the staker
   * @param tokenId the ID of the Marine to add to the MarinePool
   */
  function _addMarineToMarinePool(address account, uint256 tokenId) internal whenNotPaused _updateEarnings {
    marinePool[tokenId] = Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(block.timestamp)
    });
    numMarinesStaked += 1;
    emit TokenStaked(account, tokenId, true, block.timestamp);
  }

  /**
   * adds a single Alien to the AlienPool
   * @param account the address of the staker
   * @param tokenId the ID of the Alien to add to the AlienPool
   */
  function _addAlienToAlienPool(address account, uint256 tokenId) internal {
    uint8 rank = _rankForAlien(tokenId);
    totalRankStaked += rank; // Portion of earnings ranges from 4 to 1
    alienPoolIndices[tokenId] = alienPool[rank].length; // Store the location of the alien in the AlienPool
    alienPool[rank].push(Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(oresPerRank)
    })); // Add the alien to the AlienPool
    emit TokenStaked(account, tokenId, false, oresPerRank);
  }

  /** CLAIMING / UNSTAKING */

  /**
   * realize $ORES earnings and optionally unstake tokens from the MarinePool / AlienPool
   * to unstake a Marine it will require it has 2 days worth of $ORES unclaimed
   * @param tokenIds the IDs of the tokens to claim earnings from
   * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
   */
  function claimManyFromMarinePoolAndAlienPool(uint16[] calldata tokenIds, bool unstake) external whenNotPaused _updateEarnings nonReentrant {
    require(tx.origin == _msgSender() || _msgSender() == address(mnaGame), "Only EOA");
    uint256 owed = 0;
    for (uint i = 0; i < tokenIds.length; i++) {
      if (mnaNFT.isMarine(tokenIds[i])) {
        owed += _claimMarineFromMarinePool(tokenIds[i], unstake);
      }
      else {
        owed += _claimAlienFromAlienPool(tokenIds[i], unstake);
      }
    }
    oresToken.updateOriginAccess();
    if (owed == 0) {
      return;
    }
    oresToken.mint(_msgSender(), owed);
  }

  function calculateRewards(uint256 tokenId) external view returns (uint256 owed) {
    uint64 lastTokenWrite = mnaNFT.getTokenWriteBlock(tokenId);
    // Must check this, as getTokenTraits will be allowed since this contract is an admin
    require(lastTokenWrite < block.number, "hmmmm what doing?");
    Stake memory stake = marinePool[tokenId];
    if(mnaNFT.isMarine(tokenId)) {
      if (totalORESEarned < MAXIMUM_GLOBAL_ORES) {
        owed = (block.timestamp - stake.value) * DAILY_ORES_RATE / 1 days;
      } else if (stake.value > lastClaimTimestamp) {
        owed = 0; // $ORES production stopped already
      } else {
        owed = (lastClaimTimestamp - stake.value) * DAILY_ORES_RATE / 1 days; // stop earning additional $ORES if it's all been earned
      }
    }
    else {
      uint8 rank = _rankForAlien(tokenId);
      owed = (rank) * (oresPerRank - stake.value); // Calculate portion of tokens based on Rank
    }
  }

  /**
   * realize $ORES earnings for a single Marine and optionally unstake it
   * if not unstaking, pay a 20% tax to the staked Aliens
   * if unstaking, there is a 50% chance all $ORES is stolen
   * @param tokenId the ID of the Marines to claim earnings from
   * @param unstake whether or not to unstake the Marines
   * @return owed - the amount of $ORES earned
   */
  function _claimMarineFromMarinePool(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    Stake memory stake = marinePool[tokenId];
    require(stake.owner == _msgSender(), "Don't own the given token");
    require(!(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT), "Still guarding the marinePool");
    if (totalORESEarned < MAXIMUM_GLOBAL_ORES) {
      owed = (block.timestamp - stake.value) * DAILY_ORES_RATE / 1 days;
    } else if (stake.value > lastClaimTimestamp) {
      owed = 0; // $ORES production stopped already
    } else {
      owed = (lastClaimTimestamp - stake.value) * DAILY_ORES_RATE / 1 days; // stop earning additional $ORES if it's all been earned
    }
    if (unstake) {
      if (randomSeedGenerator.random() & 1 == 1) { // 50% chance of all $ORES stolen
        _payAlienTax(owed);
        owed = 0;
      }
      delete marinePool[tokenId];
      numMarinesStaked -= 1;
      // Always transfer last to guard against reentrance
      mnaNFT.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Marine
    } else {
      _payAlienTax(owed * ORES_CLAIM_TAX_PERCENTAGE / 100); // percentage tax to staked aliens
      owed = owed * (100 - ORES_CLAIM_TAX_PERCENTAGE) / 100; // remainder goes to Marine owner
      marinePool[tokenId] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(block.timestamp)
      }); // reset stake
    }
    emit MarineClaimed(tokenId, unstake, owed);
  }

  /**
   * realize $ORES earnings for a single Alien and optionally unstake it
   * Aliens earn $ORES proportional to their rank
   * @param tokenId the ID of the Alien to claim earnings from
   * @param unstake whether or not to unstake the Alien
   * @return owed - the amount of $ORES earned
   */
  function _claimAlienFromAlienPool(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    require(mnaNFT.ownerOf(tokenId) == address(this), "Doesn't own token");
    uint8 rank = _rankForAlien(tokenId);
    Stake memory stake = alienPool[rank][alienPoolIndices[tokenId]];
    require(!(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT), "Still guarding the alienPool");
    require(stake.owner == _msgSender(), "Doesn't own token");
    owed = (rank) * (oresPerRank - stake.value); // Calculate portion of tokens based on Rank
    if (unstake) {
      totalRankStaked -= rank; // Remove rank from total staked
      if (randomSeedGenerator.random() & 1 == 1) { // 50% chance of all $ORES stolen
        _payAlienTax(owed);
        owed = 0;
      }      
      Stake memory lastStake = alienPool[rank][alienPool[rank].length - 1];
      alienPool[rank][alienPoolIndices[tokenId]] = lastStake; // Shuffle last Alien to current position
      alienPoolIndices[lastStake.tokenId] = alienPoolIndices[tokenId];
      alienPool[rank].pop(); // Remove duplicate
      delete alienPoolIndices[tokenId]; // Delete old mapping
      // Always remove last to guard against reentrance
      mnaNFT.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Alien
    } else {
      alienPool[rank][alienPoolIndices[tokenId]] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(oresPerRank)
      }); // reset stake
    }
    emit AlienClaimed(tokenId, unstake, owed);
  }
  /**
   * emergency unstake tokens
   * @param tokenIds the IDs of the tokens to claim earnings from
   */
  function rescue(uint256[] calldata tokenIds) external nonReentrant {
    require(rescueEnabled, "RESCUE DISABLED");
    uint256 tokenId;
    Stake memory stake;
    Stake memory lastStake;
    uint8 rank;
    for (uint i = 0; i < tokenIds.length; i++) {
      tokenId = tokenIds[i];
      if (mnaNFT.isMarine(tokenId)) {
        stake = marinePool[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        delete marinePool[tokenId];
        numMarinesStaked -= 1;
        mnaNFT.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Marines
        emit MarineClaimed(tokenId, true, 0);
      } else {
        rank = _rankForAlien(tokenId);
        stake = alienPool[rank][alienPoolIndices[tokenId]];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        totalRankStaked -= rank; // Remove Rank from total staked
        lastStake = alienPool[rank][alienPool[rank].length - 1];
        alienPool[rank][alienPoolIndices[tokenId]] = lastStake; // Shuffle last Alien to current position
        alienPoolIndices[lastStake.tokenId] = alienPoolIndices[tokenId];
        alienPool[rank].pop(); // Remove duplicate
        delete alienPoolIndices[tokenId]; // Delete old mapping
        mnaNFT.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Alien
        emit AlienClaimed(tokenId, true, 0);
      }
    }
  }

  /** ACCOUNTING */

  /** 
   * add $ORES to claimable pot for the AlienPool
   * @param amount $ORES to add to the pot
   */
  function _payAlienTax(uint256 amount) internal {
    if (totalRankStaked == 0) { // if there's no staked aliens
      unaccountedRewards += amount; // keep track of $ORES due to aliens
      return;
    }
    // makes sure to include any unaccounted $ORES 
    oresPerRank += (amount + unaccountedRewards) / totalRankStaked;
    unaccountedRewards = 0;
  }

  /**
   * tracks $ORES earnings to ensure it stops once 2.4 billion is eclipsed
   */
  modifier _updateEarnings() {
    if (totalORESEarned < MAXIMUM_GLOBAL_ORES) {
      totalORESEarned += 
        (block.timestamp - lastClaimTimestamp)
        * numMarinesStaked
        * DAILY_ORES_RATE / 1 days; 
      lastClaimTimestamp = block.timestamp;
    }
    _;
  }

  /** ADMIN */

  /**
   * allows owner to enable "rescue mode"
   * simplifies accounting, prioritizes tokens out in emergency
   */
  function setRescueEnabled(bool _enabled) external onlyOwner {
    rescueEnabled = _enabled;
  }

  /**
   * enables owner to pause / unpause contract
   */
  function setPaused(bool _paused) external requireContractsSet onlyOwner {
    if (_paused) _pause();
    else _unpause();
  }

  /** READ ONLY */

  /**
   * gets the rank score for a Alien
   * @param tokenId the ID of the Alien to get the rank score for
   * @return the rank score of the Alien (5-8)
   */
  function _rankForAlien(uint256 tokenId) internal view returns (uint8) {
    IMnA.MarineAlien memory s = mnaNFT.getTokenTraits(tokenId);
    return MAX_RANK - s.rankIndex; // rank index is 0-3
  }

  /**
   * chooses a random Alien thief when a newly minted token is stolen
   * @param seed a random value to choose a Alien from
   * @return the owner of the randomly selected Alien thief
   */
  function randomAlienOwner(uint256 seed) external view override returns (address) {
    if (totalRankStaked == 0) {
      return address(0x0);
    }
    uint256 bucket = (seed & 0xFFFFFFFF) % totalRankStaked; // choose a value from 0 to total rank staked
    uint256 cumulative;
    seed >>= 32;
    // loop through each bucket of Aliens with the same rank score
    for (uint i = MAX_RANK - 3; i <= MAX_RANK; i++) {
      cumulative += alienPool[i].length * i;
      // if the value is not inside of that bucket, keep going
      if (bucket >= cumulative) continue;
      // get the address of a random Alien with that rank score
      return alienPool[i][seed % alienPool[i].length].owner;
    }
    return address(0x0);
  }

  function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
      require(from == address(0x0), "Cannot send to MarinePool directly");
      return IERC721Receiver.onERC721Received.selector;
    }

  
}