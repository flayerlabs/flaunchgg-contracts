// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IL2ToL2CrossDomainMessenger} from '@optimism/interfaces/L2/IL2ToL2CrossDomainMessenger.sol';
import {Predeploys} from '@optimism/src/libraries/Predeploys.sol';

import {Initializable} from '@solady/utils/Initializable.sol';
import {ERC721} from '@solady/tokens/ERC721.sol';
import {LibClone} from '@solady/utils/LibClone.sol';
import {LibString} from '@solady/utils/LibString.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {IFlaunch} from '@flaunch-interfaces/IFlaunch.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';


/**
 * The Flaunch ERC721 NFT that is created when a new position is by the {PositionManager} flaunched.
 * This is used to prove ownership of a pool, so transferring this token would result in a new
 * pool creator being assigned.
 */
contract Flaunch is ERC721, IFlaunch, Initializable, Ownable {

    error CallerNotL2ToL2CrossDomainMessenger();
    error CallerIsNotPositionManager();
    error CreatorFeeAllocationInvalid(uint24 _allocation, uint _maxAllocation);
    error InvalidCrossDomainSender();
    error InvalidDestinationChain();
    error InvalidFlaunchSchedule();
    error InvalidInitialSupply(uint _initialSupply);
    error PremineExceedsInitialAmount(uint _buyAmount, uint _initialSupply);
    error TokenAlreadyBridging();
    error TokenAlreadyBridged();
    error UnknownMemecoin();

    event TokenBridging(uint _tokenId, uint _chainId, address _memecoin);
    event TokenBridged(uint _tokenId, uint _chainId, address _memecoin, uint _messageSource);
    event BaseURIUpdated(string _newBaseURI);
    event MemecoinImplementationUpdated(address _newImplementation);
    event MemecoinTreasuryImplementationUpdated(address _newImplementation);

    /**
     * Stores related memecoin contract implementation addresses.
     *
     * @member memecoin The ERC20 {Memecoin} address
     * @member memecoinTreasury The {MemecoinTreasury} address
     */
    struct TokenInfo {
        address memecoin;
        address payable memecoinTreasury;
    }

    /**
     * Stores the metadata for a memecoin for bridging.
     *
     * @member name The name of the memecoin
     * @member symbol The symbol of the memecoin
     * @member tokenUri The token URI for the memecoin
     */
    struct MemecoinMetadata {
        string name;
        string symbol;
        string tokenUri;
    }

    /// The L2 to L2 cross domain messenger predeploy to handle message passing
    IL2ToL2CrossDomainMessenger internal messenger = IL2ToL2CrossDomainMessenger(Predeploys.L2_TO_L2_CROSS_DOMAIN_MESSENGER);

    /// The maximum amount of tokens that can be attributed to the Fair Launch
    uint public constant MAX_FAIR_LAUNCH_TOKENS = TokenSupply.INITIAL_SUPPLY;

    /// The maximum value of a creator's fee allocation
    uint public constant MAX_CREATOR_ALLOCATION = 100_00;

    /// The maximum duration of a flaunch schedule
    uint public constant MAX_SCHEDULE_DURATION = 30 days;

    /// The maximum amount of time to allow for a bridging finalization before allowing a retry
    uint public constant MAX_BRIDGING_WINDOW = 1 hours;

    /// Our basic token information
    string internal _name = 'Flaunch Revenue Streams';
    string internal _symbol = 'FLAUNCH';

    /// The base URI to represent the metadata
    string public baseURI;

    /// Stores the next tokenId that will be minted. This can be used as an indication of how
    /// many tokens currently exist in the protocol.
    uint public nextTokenId = 1;

    /// The Flaunch {PositionManager} contract
    PositionManager public positionManager;

    /// Our token implementations that will be deployed when a new token is flaunched
    address public memecoinImplementation;
    address public memecoinTreasuryImplementation;

    /// Maps `TokenInfo` for each token ID
    mapping (uint _tokenId => TokenInfo _tokenInfo) internal tokenInfo;

    /// Maps a {Memecoin} ERC20 address to it's token ID
    mapping (address _memecoin => uint _tokenId) public tokenId;

    /// Maps our ERC20 bridging statuses
    mapping (uint _tokenId => mapping (uint _chainId => uint _startedAt)) public bridgingStarted;
    mapping (uint _tokenId => mapping (uint _chainId => bool _finalized)) public bridgingFinalized;


    /**
     * References the contract addresses for the Flaunch protocol.
     *
     * @param _memecoinImplementation The {Memecoin} implementation address
     * @param _baseURI The default baseUri for the ERC721
     */
    constructor (address _memecoinImplementation, string memory _baseURI) {  // 初始化Flaunch合约，设置memecoin实现地址和基础URI
        memecoinImplementation = _memecoinImplementation;
        baseURI = _baseURI;

        _initializeOwner(msg.sender);  // 初始化合约所有者
    }

    /**
     * Adds the {PositionManager} and {MemecoinTreasury} implementation addresses required to
     * actually flaunch tokens, converting the contract from a satellite contract into a fully
     * fledged Flaunch protocol implementation.
     *
     * @param _positionManager The Flaunch {PositionManager} 
     * @param _memecoinTreasuryImplementation The {MemecoinTreasury} implementation address   金库实现地址
     */
    function initialize(PositionManager _positionManager, address _memecoinTreasuryImplementation) external onlyOwner initializer {
        positionManager = _positionManager;
        memecoinTreasuryImplementation = _memecoinTreasuryImplementation;
    }

    /**
     * Flaunches a new token, deploying the required implementations and creating a new ERC721. The
     * tokens are sent to the `_creator` to prove ownership of the pool.
     * 创建一个新的token，部署所需的实现并创建一个新的ERC721。将token发送给`_creator`以证明对池的所有权。
     */
    function flaunch(
        PositionManager.FlaunchParams calldata _params
    ) external override onlyPositionManager returns (
        address memecoin_,
        address payable memecoinTreasury_,
        uint tokenId_
    ) {
        // Check if the flaunch timestamp surpasses the max schedule duration
        if (_params.flaunchAt > block.timestamp + MAX_SCHEDULE_DURATION) revert InvalidFlaunchSchedule();

        // Ensure that the initial supply falls within an accepted range
        if (_params.initialTokenFairLaunch > MAX_FAIR_LAUNCH_TOKENS) revert InvalidInitialSupply(_params.initialTokenFairLaunch);

        // Check that user isn't trying to premine too many tokens
        if (_params.premineAmount > _params.initialTokenFairLaunch) revert PremineExceedsInitialAmount(_params.premineAmount, _params.initialTokenFairLaunch);

        // A creator cannot set their allocation above a threshold
        if (_params.creatorFeeAllocation > MAX_CREATOR_ALLOCATION) revert CreatorFeeAllocationInvalid(_params.creatorFeeAllocation, MAX_CREATOR_ALLOCATION);

        // Store the current token ID and increment the next token ID
        tokenId_ = nextTokenId;
        unchecked { nextTokenId++; }

        // Mint ownership token to the creator
        _mint(_params.creator, tokenId_);

        // Deploy the memecoin
        memecoin_ = LibClone.cloneDeterministic(memecoinImplementation, bytes32(tokenId_));

        // Store the token ID
        tokenId[memecoin_] = tokenId_;

        // Initialize the memecoin with the metadata
        IMemecoin _memecoin = IMemecoin(memecoin_);
        _memecoin.initialize(_params.name, _params.symbol, _params.tokenUri);

        // Deploy the memecoin treasury
        memecoinTreasury_ = payable(
            LibClone.cloneDeterministic(memecoinTreasuryImplementation, bytes32(tokenId_))
        );

        // Store the token info
        tokenInfo[tokenId_] = TokenInfo(memecoin_, memecoinTreasury_);

        // Mint our initial supply to the {PositionManager}
        _memecoin.mint(address(positionManager), TokenSupply.INITIAL_SUPPLY);
    }

    /**
     * Allows a contract owner to update the name and symbol of the ERC20 token so
     * that if one is created with malformed, unintelligible or offensive data then
     * we can replace it.  当一个memecoin创建的不理想，可以修改
     *
     * @param _memecoin The memecoin address
     * @param name_ The new name for the token
     * @param symbol_ The new symbol for the token
     */
    function setMemecoinMetadata(
        address _memecoin,
        string calldata name_,
        string calldata symbol_
    ) external onlyOwner {
        IMemecoin(_memecoin).setMetadata(name_, symbol_);
    }

    /**
     * Allows a contract owner to update the base URI for the creator ERC721 tokens.
     * 
     * @param _baseURI The new base URI
     */
    function setBaseURI(string memory _baseURI) external onlyOwner {
        baseURI = _baseURI;
        emit BaseURIUpdated(_baseURI);
    }

    /**
     * Allows the contract owner to update the memecoin implementation address.
     * 
     * @param _memecoinImplementation The new memecoin implementation address
     */
    function setMemecoinImplementation(address _memecoinImplementation) external onlyOwner {
        memecoinImplementation = _memecoinImplementation;
        emit MemecoinImplementationUpdated(_memecoinImplementation);
    }

    /**
     * Allows the contract owner to update the memecoin treasury implementation address.
     * 
     * @param _memecoinTreasuryImplementation The new memecoin treasury implementation address
     */
    function setMemecoinTreasuryImplementation(address _memecoinTreasuryImplementation) external onlyOwner {
        memecoinTreasuryImplementation = _memecoinTreasuryImplementation;
        emit MemecoinTreasuryImplementationUpdated(_memecoinTreasuryImplementation);
    }

    /**
     * Returns the ERC721 name.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * Returns the ERC721 symbol.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * Returns the Uniform Resource Identifier (URI) for token id.
     * 根据id返回URI，如果token被销毁，则返回空字符串
     * @dev We prevent the token from erroring if it was burned, and instead we just check against
     * the current tokenId iteration we have stored.
     *
     * @param _tokenId The token ID to get the URI for
     */
    function tokenURI(uint _tokenId) public view override returns (string memory) {
        // If we are ahead of our tracked tokenIds, then revert
        if (_tokenId == 0 || _tokenId >= nextTokenId) revert TokenDoesNotExist();

        // If the base URI is empty, return the memecoin token URI
        if (bytes(baseURI).length == 0) {
            return IMemecoin(tokenInfo[_tokenId].memecoin).tokenURI();
        }

        // Otherwise, concatenate the base URI and the token ID
        return LibString.concat(baseURI, LibString.toString(_tokenId));
    }

    /**
     * Helper to show the {Memecoin} address for the ERC721.
     * 根据id返回memecoin地址
     * @param _tokenId The token ID to get the {Memecoin} for
     *
     * @return address {Memecoin} address
     */
    function memecoin(uint _tokenId) public view returns (address) {
        return tokenInfo[_tokenId].memecoin;
    }

    /**
     * Helper to show the {MemecoinTreasury} address for the ERC721.
     * 根据id返回memecoin金库地址
     * @param _tokenId The token ID to get the {MemecoinTreasury} for
     *
     * @return address {MemecoinTreasury} address
     */
    function memecoinTreasury(uint _tokenId) public view returns (address payable) {
        return tokenInfo[_tokenId].memecoinTreasury;
    }

    /**
     * Helper to show the {PoolId} address for the ERC721 token.
     * 根据id返回poolId地址
     * @param _tokenId The token ID to get the {PoolId} for
     *
     * @return PoolId The {PoolId} for the token
     */
    function poolId(uint _tokenId) public view returns (PoolId) {
        return positionManager.poolKey(tokenInfo[_tokenId].memecoin).toId();
    }

    /**
     * Burns `tokenId` by sending it to `address(0)`.
     *
     * @dev The caller must own `tokenId` or be an approved operator.
     *
     * @param _tokenId The token ID to check
     */
    function burn(uint _tokenId) public {
        _burn(msg.sender, _tokenId);
    }

    /**
     * Allows anyone to trigger their token to be bridged to another L2. This will then relay the
     * message to the other L2 which will complete the bridging flow in the `finalizeBridge`
     * function call.
     * 允许任何人触发他们的token被桥接到另一个L2。这将然后传递消息到另一个L2，在`finalizeBridge`函数中完成桥接流程。
     * The token contract will be created with the same salt as the initial token, so the address
     * will persist, but won't mint an initial supply like the `flaunch` function call does.
     * token合约将被创建与初始token相同的盐，所以地址将持久化，但不会像`flaunch`函数调用那样铸造初始供应。
     * @dev More information regarding Superchain Interoperability can be found
     * [here](https://supersim.pages.dev/guides/interop/).
     * 更多关于Superchain Interoperability的信息可以在这里找到：https://supersim.pages.dev/guides/interop/
     * @param _tokenId The ERC721 memestream tokenId to bridge the memecoin of
     * @param _chainId The destination L2 chainId
     */
    function initializeBridge(uint _tokenId, uint _chainId) public {
        // Ensure that we are not calling the same chain
        if (_chainId == block.chainid) {
            revert InvalidDestinationChain();
        }

        // Ensure that the bridge has not already been finalized
        if (bridgingFinalized[_tokenId][_chainId]) {
            revert TokenAlreadyBridged();
        }

        // If the token bridging process has already been started, then we don't allow this
        // to be triggered again for a set window of time.
        if (
            bridgingStarted[_tokenId][_chainId] != 0 &&
            block.timestamp < bridgingStarted[_tokenId][_chainId] + MAX_BRIDGING_WINDOW
        ) {
            revert TokenAlreadyBridging();
        }

        // Update our bridging status to show it has started
        bridgingStarted[_tokenId][_chainId] = block.timestamp;

        // Find the memecoin for metadata discovery
        address memecoinAddress = memecoin(_tokenId);

        // If we were unable to discover the memecoin, then there is nothing to bridge
        if (memecoinAddress == address(0)) {
            revert UnknownMemecoin();
        }

        // Send the memecoin data to another L2. On previous versions of Superchain Interoperability
        // this would revert in the `sendMessage` call if the target contract did not exist. However,
        // in recent updates this is no longer the case, so we need to allow for this to be retried
        // at a later date.
        IMemecoin _memecoin = IMemecoin(memecoinAddress);
        messenger.sendMessage(
            _chainId,
            address(this),
            abi.encodeCall(
                this.finalizeBridge,
                (
                    _tokenId,
                    MemecoinMetadata({
                        name: _memecoin.name(),
                        symbol: _memecoin.symbol(),
                        tokenUri: _memecoin.tokenURI()
                    })
                )
            )
        );

        emit TokenBridging(_tokenId, _chainId, memecoinAddress);
    }

    /**
     * Called after the `initializeBridge` function to validate the bridging request and subsequently
     * deploy the memecoin contract code onto the L2 chain.
     * 在`initializeBridge`函数之后调用，验证桥接请求并随后部署memecoin合约代码到L2链。
     * @param _tokenId The ERC721 memestream tokenId that is being bridged
     * @param _metadata Memecoin token metadata to initialize with
     */
    function finalizeBridge(uint _tokenId, MemecoinMetadata memory _metadata) public onlyCrossDomainCallback {
        // Map our bridging as being finalized
        bridgingFinalized[_tokenId][block.chainid] = true;

        // Deploy the token on this chain
        address memecoin_ = LibClone.cloneDeterministic(memecoinImplementation, bytes32(_tokenId));

        // Initialize the memecoin with the metadata
        IMemecoin(memecoin_).initialize(_metadata.name, _metadata.symbol, _metadata.tokenUri);

        // Update our bridging status
        emit TokenBridged(_tokenId, block.chainid, memecoin_, messenger.crossDomainMessageSource());
    }

    /**
     * Ensures that only the immutable {PositionManager} can call the function.
     */
    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) {
            revert CallerIsNotPositionManager();
        }
        _;
    }

    /**
     * Modifier to restrict a function to only be a cross-domain callback into this contract.
     */
    modifier onlyCrossDomainCallback() {
        if (msg.sender != address(messenger)) revert CallerNotL2ToL2CrossDomainMessenger();
        if (messenger.crossDomainMessageSender() != address(this)) revert InvalidCrossDomainSender();

        _;
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     * 防止所有者被重新初始化。
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
