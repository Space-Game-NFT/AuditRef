// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import "./interfaces/IMnA.sol";
import "./interfaces/IStakingPool.sol";
import "./interfaces/ITraits.sol";
import "./interfaces/IRandomSeedGenerator.sol";
import "./interfaces/IFounderPass.sol";

import "./libraries/ERC721A.sol";


contract MnA is IMnA, IERC721Receiver, ERC721Enumerable, Ownable, Pausable {

    struct LastWrite {
        uint64 time;
        uint64 blockNum;
    }

    event MarineMinted(uint256 indexed tokenId);
    event AlienMinted(uint256 indexed tokenId);
    event MarineStolen(uint256 indexed tokenId);
    event AlienStolen(uint256 indexed tokenId);
    event MarineBurned(uint256 indexed tokenId);
    event AlienBurned(uint256 indexed tokenId);

    // max number of tokens that can be minted
    uint256 public maxTokens = 28000;
    // number of tokens that can be airdropped for a fee
    uint256 public PAID_TOKENS = 6969;
    // number of tokens that admin can mint for airdrop at a time
    uint256 public airdropMintingCount = 100;
    // number of tokens have been minted so far
    uint16 public override minted;
    // flag to show airdrop stage
    bool public isAirdropStage;

    // mapping from tokenId to a struct containing the token's traits
    mapping(uint256 => MarineAlien) private tokenTraits;
    // mapping from hashed(tokenTrait) to the tokenId it's associated with
    // used to ensure there are no duplicates
    mapping(uint256 => uint256) public existingCombinations;
    // Tracks the last block and timestamp that a caller has written to state.
    // Disallow some access to functions if they occur while a change is being written.
    mapping(address => LastWrite) private lastWriteAddress;
    mapping(uint256 => LastWrite) private lastWriteToken;

    // list of probabilities for each trait type
    // 0 - 5 are associated with Marine, 6 - 11 are associated with Aliens
    uint8[][12] public rarities;
    // list of aliases for Walker's Alias algorithm
    // 0 - 5 are associated with Marine, 6 - 11 are associated with Aliens
    uint8[][12] public aliases;

    // reference to the Tower contract to allow transfers to it without approval
    IStakingPool public stakingPool;
    // reference to Traits
    ITraits public traits;
    // random seed generator
    IRandomSeedGenerator public randomSeedGenerator;
    // founder pass
    IFounderPass public founderPass;

    // address => allowedToCallFunctions
    mapping(address => bool) private admins;

    constructor(address _founderPass) ERC721("Marines & Aliens Game", "MnA") {
        _pause();

        // A.J. Walker's Alias Algorithm
        // Marines
        // Weapon
        rarities[0] =  [255, 38, 50, 237, 211, 201, 248, 61, 8, 45, 106, 18, 122, 49, 45, 34, 19, 16];
        aliases[0] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 11];
        // Back
        rarities[1] = [255, 204, 30, 225, 71, 245, 196, 81, 40, 28, 20];
        aliases[1] = [0, 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 4];        
        // Headgear
        rarities[2] = [255, 188, 14, 219, 208, 239, 55, 75, 137, 239, 126, 47, 245, 221, 163, 122, 81, 40];
        aliases[2] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 4, 5, 6, 7, 8, 11];
        // Eyes
        rarities[3] = [255, 38, 50, 237, 211, 201, 248, 61, 8, 45, 106, 18, 122, 49, 45, 34, 19, 16];
        aliases[3] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 11];
        // Emblem
        rarities[4] = [255, 151, 239, 219, 215, 104, 18, 229, 208, 229, 26, 112, 231, 118, 47, 245, 196, 163, 122, 65];
        aliases[4] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 6, 7, 8, 10, 11, 14];
        // Body
        rarities[5] = [255, 73, 114, 186, 43, 204, 184, 204, 241, 55, 198, 102, 30, 245, 204, 163, 131, 98, 65, 40];
        aliases[5] = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 3, 4, 4, 5, 6, 7, 9, 12];

        // Aliens
        // Headgear
        rarities[6] = [255, 71, 163, 102, 122, 163, 51, 245, 180, 86, 20];
        aliases[6] = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 1, 1, 2, 3, 4, 6];
        // Eye
        rarities[7] = [255, 112, 204, 102, 81, 184, 71, 245, 163, 61, 20];
        aliases[7] = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 1, 1, 2, 3, 4, 6];
        // Back
        rarities[8] = [255, 245, 143, 81, 61, 122, 10, 204, 163, 81, 20];
        aliases[8] = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 0, 1, 2, 3, 4, 6];          
        // Mouth
        rarities[9] = [255, 245, 143, 81, 61, 122, 10, 204, 163, 81, 20];
        aliases[9] = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 0, 1, 2, 3, 4, 6];
        // Body
        rarities[10] = [255, 51, 143, 40, 20, 122, 51, 204, 163, 122, 20];
        aliases[10] = [0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 1, 1, 2, 3, 4, 6];
              

        // rankIndex
        rarities[11] = [255, 79, 165, 25];
        aliases[11] = [0, 1, 1, 1];

        founderPass = IFounderPass(_founderPass);
    }

    modifier requireContractsSet() {
        require(address(traits) != address(0) && address(stakingPool) != address(0) && address(randomSeedGenerator) != address(0), "Contracts not set");
        _;
    }

    modifier blockIfChangingAddress() {
        // frens can always call whenever they want :)
        require(admins[_msgSender()] || lastWriteAddress[tx.origin].blockNum < block.number, "hmmmm what doing?");
        _;
    }

    modifier blockIfChangingToken(uint256 tokenId) {
        // frens can always call whenever they want :)
        require(admins[_msgSender()] || lastWriteToken[tokenId].blockNum < block.number, "hmmmm what doing?");
        _;
    }

    function setContracts(address _traits, address _stakingPool, address _randomSeedGenerator) external onlyOwner {
        traits = ITraits(_traits);
        stakingPool = IStakingPool(_stakingPool);
        randomSeedGenerator = IRandomSeedGenerator(_randomSeedGenerator);
    }

    function getTokenWriteBlock(uint256 tokenId) external view override returns(uint64) {
        require(admins[_msgSender()], "Only admins can call this");
        return lastWriteToken[tokenId].blockNum;
    }

    function mintForAirdrop() external onlyOwner whenNotPaused {
        require(isAirdropStage, "Airdrop minting is only available in airdrop stage");
        require(PAID_TOKENS > minted, "Airdrop minting completed");
        require(address(randomSeedGenerator) != address(0), "random seed generator is null");
        
        uint256 _mintCount = airdropMintingCount;
        if (PAID_TOKENS < minted + airdropMintingCount) _mintCount = PAID_TOKENS - minted;
        for (uint256 i = 0; i < _mintCount; i++) {
            uint256 randomNumber = uint256(keccak256(abi.encode(randomSeedGenerator.random(), minted)));
            mint(address(this), randomNumber);
        }
    }

    function claim() external whenNotPaused {
        uint256 balance = founderPass.balanceOf(msg.sender);
        for (uint256 index = 0; index < balance; index++) {
            uint256 tokenId = founderPass.tokenOfOwnerByIndex(msg.sender, index);
            require(IERC721(address(this)).ownerOf(tokenId) == address(this), "Invalid tokenId"); 
            IERC721(address(this)).safeTransferFrom(address(this), msg.sender, tokenId + 1);
        }
    }

    /** 
    * Mint a token - any payment / game logic should be handled in the game contract. 
    * This will just generate random traits and mint a token to a designated address.
    */
    function mint(address recipient, uint256 seed) public override whenNotPaused {
        require(admins[_msgSender()], "Only admins can call this");
        require(minted + 1 <= maxTokens, "All tokens minted");
        minted++;
        generate(minted, seed, lastWriteAddress[tx.origin]);
        if(tx.origin != recipient && recipient != address(stakingPool) && recipient != address(this)) {
            // Stolen!
            if(tokenTraits[minted].isMarine) {
                emit MarineStolen(minted);
            }
            else {
                emit AlienStolen(minted);
            }
        }
        _safeMint(recipient, minted);
    }

    /**
    * Burn a token - any game logic should be handled before this function.
    */
    function burn(uint256 tokenId) external override whenNotPaused {
        require(admins[_msgSender()], "Only admins can call this");
        require(ownerOf(tokenId) == tx.origin, "Oops you don't own that");
        if(tokenTraits[tokenId].isMarine) {
            emit MarineBurned(tokenId);
        }
        else {
            emit AlienBurned(tokenId);
        }
        _burn(tokenId);
    }

    function updateOriginAccess(uint16[] memory tokenIds) external override {
        require(admins[_msgSender()], "Only admins can call this");
        uint64 blockNum = uint64(block.number);
        uint64 time = uint64(block.timestamp);
        lastWriteAddress[tx.origin] = LastWrite(time, blockNum);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            lastWriteToken[tokenIds[i]] = LastWrite(time, blockNum);
        }
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override(ERC721, IERC721) blockIfChangingToken(tokenId) {
        // allow admin contracts to be send without approval
        if(!admins[_msgSender()]) {
            require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC721: transfer caller is not owner nor approved");
        }
        _transfer(from, to, tokenId);
    }

    /** INTERNAL */

    /**
    * generates traits for a specific token, checking to make sure it's unique
    * @param tokenId the id of the token to generate traits for
    * @param seed a pseudorandom 256 bit number to derive traits from
    * @return t - a struct of traits for the given token ID
    */
    function generate(uint256 tokenId, uint256 seed, LastWrite memory lw) internal returns (MarineAlien memory t) {
        t = selectTraits(seed);
        if (existingCombinations[structToHash(t)] == 0) {
            tokenTraits[tokenId] = t;
            existingCombinations[structToHash(t)] = tokenId;
            if(t.isMarine) {
                emit MarineMinted(tokenId);
            }
            else {
                emit AlienMinted(tokenId);
            }
            return t;
        }
        uint256 nextSeed = uint256(keccak256(abi.encode(randomSeedGenerator.random(), seed)));
        return generate(tokenId, nextSeed, lw);
    }

    /**
    * uses A.J. Walker's Alias algorithm for O(1) rarity table lookup
    * ensuring O(1) instead of O(n) reduces mint cost by more than 50%
    * probability & alias tables are generated off-chain beforehand
    * @param seed portion of the 256 bit seed to remove trait correlation
    * @param traitType the trait type to select a trait for 
    * @return the ID of the randomly selected trait
    */
    function selectTrait(uint16 seed, uint8 traitType) internal view returns (uint8) {
        uint8 trait = uint8(seed) % uint8(rarities[traitType].length);
        // If a selected random trait probability is selected (biased coin) return that trait
        if (seed >> 8 < rarities[traitType][trait]) return trait;
        return aliases[traitType][trait];
    }

    /**
    * selects the species and all of its traits based on the seed value
    * @param seed a pseudorandom 256 bit number to derive traits from
    * @return t -  a struct of randomly selected traits
    */
    function selectTraits(uint256 seed) internal view returns (MarineAlien memory t) {    
        t.isMarine = (seed & 0xFFFF) % 10 != 0;

        if (t.isMarine) {
            seed >>= 16;    
            t.M_Weapon = selectTrait(uint16(seed & 0xFFFF), 0);
            seed >>= 16;
            t.M_Back = selectTrait(uint16(seed & 0xFFFF), 1);
            seed >>= 16;
            t.M_Headgear = selectTrait(uint16(seed & 0xFFFF), 2);
            seed >>= 16;
            t.M_Eyes = selectTrait(uint16(seed & 0xFFFF), 3);
            seed >>= 16;
            t.M_Emblem = selectTrait(uint16(seed & 0xFFFF), 4);
            seed >>= 16;
            t.M_Body = selectTrait(uint16(seed & 0xFFFF), 5);
        } else {
            seed >>= 16;    
            t.A_Headgear = selectTrait(uint16(seed & 0xFFFF), 0);
            seed >>= 16;
            t.A_Eye = selectTrait(uint16(seed & 0xFFFF), 1);
            seed >>= 16;
            t.A_Back = selectTrait(uint16(seed & 0xFFFF), 2);
            seed >>= 16;
            t.A_Mouth = selectTrait(uint16(seed & 0xFFFF), 3);
            seed >>= 16;
            t.A_Body = selectTrait(uint16(seed & 0xFFFF), 4);
            seed >>= 16;
            t.rankIndex = selectTrait(uint16(seed & 0xFFFF), 5);
        }
    }

    /**
    * converts a struct to a 256 bit hash to check for uniqueness
    * @param s the struct to pack into a hash
    * @return the 256 bit hash of the struct
    */
    function structToHash(MarineAlien memory s) internal pure returns (uint256) {
        return uint256(keccak256(
            abi.encodePacked(
                s.isMarine,
                s.M_Weapon,
                s.M_Back,
                s.M_Headgear,
                s.M_Eyes,
                s.M_Emblem,
                s.M_Body,
                s.A_Headgear,
                s.A_Eye,
                s.A_Back,
                s.A_Mouth,
                s.A_Body,
                s.rankIndex
            )
        ));
    }

    /** READ */

    /**
    * checks if a token is a Marines
    * @param tokenId the ID of the token to check
    * @return marine - whether or not a token is a Marines
    */
    function isMarine(uint256 tokenId) external view override blockIfChangingToken(tokenId) returns (bool) {
        // Sneaky aliens will be slain if they try to peep this after mint. Nice try.
        IMnA.MarineAlien memory s = tokenTraits[tokenId];
        return s.isMarine;
    }

    function getMaxTokens() external view override returns (uint256) {
        return maxTokens;
    }

    function getPaidTokens() external view override returns (uint256) {
        return PAID_TOKENS;
    }

    /**
    * updates the number of tokens for sale
    */
    function setPaidTokens(uint256 _paidTokens) external onlyOwner {
        PAID_TOKENS = uint16(_paidTokens);
    }

    /**
     * start or end airdrop stage
     */
    function setAirdropStage(bool _isAirdropStage) external onlyOwner {
        isAirdropStage = _isAirdropStage;
    }

    /**
     * set the number of tokens to mint at a time for airdrop.
     */
    function setAirdropMintingCount(uint256 _airdropMintingCount) external onlyOwner {
        airdropMintingCount = _airdropMintingCount;
    }

    /**
    * enables owner to pause / unpause minting
    */
    function setPaused(bool _paused) external requireContractsSet onlyOwner {
        if (_paused) _pause();
        else _unpause();
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

    function getTokenTraits(uint256 tokenId) external view override blockIfChangingAddress blockIfChangingToken(tokenId) returns (MarineAlien memory) {
        return tokenTraits[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override blockIfChangingAddress blockIfChangingToken(tokenId) returns (string memory) {
        require(_exists(tokenId), "Token ID does not exist");
        return traits.tokenURI(tokenId);
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) public view virtual override(ERC721Enumerable, IERC721Enumerable) blockIfChangingAddress returns (uint256) {
        require(admins[_msgSender()] || lastWriteAddress[owner].blockNum < block.number, "hmmmm what doing?");
        uint256 tokenId = super.tokenOfOwnerByIndex(owner, index);
        require(admins[_msgSender()] || lastWriteToken[tokenId].blockNum < block.number, "hmmmm what doing?");
        return tokenId;
    }
    
    function balanceOf(address owner) public view virtual override(ERC721, IERC721) blockIfChangingAddress returns (uint256) {
        require(admins[_msgSender()] || lastWriteAddress[owner].blockNum < block.number, "hmmmm what doing?");
        return super.balanceOf(owner);
    }

    function ownerOf(uint256 tokenId) public view virtual override(ERC721, IERC721) blockIfChangingAddress blockIfChangingToken(tokenId) returns (address) {
        address addr = super.ownerOf(tokenId);
        require(admins[_msgSender()] || lastWriteAddress[addr].blockNum < block.number, "hmmmm what doing?");
        return addr;
    }

    function tokenByIndex(uint256 index) public view virtual override(ERC721Enumerable, IERC721Enumerable) returns (uint256) {
        uint256 tokenId = super.tokenByIndex(index);
        require(admins[_msgSender()] || lastWriteToken[tokenId].blockNum < block.number, "hmmmm what doing?");
        return tokenId;
    }

    function approve(address to, uint256 tokenId) public virtual override(ERC721, IERC721) blockIfChangingToken(tokenId) {
        super.approve(to, tokenId);
    }

    function getApproved(uint256 tokenId) public view virtual override(ERC721, IERC721) blockIfChangingToken(tokenId) returns (address) {
        return super.getApproved(tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public virtual override(ERC721, IERC721) blockIfChangingAddress {
        super.setApprovalForAll(operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view virtual override(ERC721, IERC721) blockIfChangingAddress returns (bool) {
        return super.isApprovedForAll(owner, operator);
    }
    
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public virtual override(ERC721, IERC721) blockIfChangingToken(tokenId) {
        super.safeTransferFrom(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public virtual override(ERC721, IERC721) blockIfChangingToken(tokenId) {
        super.safeTransferFrom(from, to, tokenId, _data);
    }

    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
      return IERC721Receiver.onERC721Received.selector;
    }    

}