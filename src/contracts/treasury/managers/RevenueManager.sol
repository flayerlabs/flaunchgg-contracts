// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {TreasuryManager} from '@flaunch/treasury/managers/TreasuryManager.sol';


/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
contract RevenueManager is TreasuryManager {

    using EnumerableSet for EnumerableSet.UintSet;

    error FailedToClaim();
    error InvalidClaimer();
    error InvalidCreatorAddress();
    error InvalidProtocolFee();

    event CreatorUpdated(address indexed _flaunch, uint indexed _tokenId, address _creator);
    event ManagerInitialized(address _owner, InitializeParams _params);
    event ProtocolFeeUpdated(uint _protocolFee);
    event ProtocolRecipientUpdated(address _protocolRecipient);
    event ProtocolRevenueClaimed(address _recipient, uint _amount);
    event RevenueClaimed(address indexed _flaunch, uint indexed _tokenId, address _recipient, uint _amount);

    /**
     * Parameters passed during manager initialization.
     *
     * @member protocolRecipient The recipient of protocol fees
     * @member protocolFee The fee that the external protocol will take (2dp)
     */
    struct InitializeParams {
        address payable protocolRecipient;
        uint protocolFee;
    }

    /// The maximum value of a protocol fee
    uint internal constant MAX_PROTOCOL_FEE = 100_00;

    /// The recipient of the protocol revenue split
    address payable public protocolRecipient;

    /// The fee that the external protocol will take (2dp)
    uint public protocolFee;

    /// Stores the amount held internally that each address can claim
    uint internal _protocolAvailableClaim;
    uint public protocolTotalClaimed;

    /// Holds an internal ID counter
    uint internal _nextInternalId;

    /// Stores an enumerable set of all creator's tokens
    mapping (address _creator => EnumerableSet.UintSet _creatorTokens) internal _creatorTokens;

    /// Maps a flaunch contract and tokenId to an internal ID
    mapping (uint _internalId => FlaunchToken _flaunchToken) public internalIds;
    mapping (address _flaunch => mapping (uint _tokenId => uint _internalId)) public flaunchTokenInternalIds;

    /// Maps a flaunch contract and tokenId to the creator
    mapping (address _flaunch => mapping (uint _tokenId => address _creator)) public creator;

    /// Tracks the total claims for creators and tokens
    mapping (address _creator => uint _claimed) public creatorTotalClaimed;
    mapping (address _flaunch => mapping (uint _tokenId => uint _claimed)) public tokenTotalClaimed;

    /// Internally caches the totalFeeAllocation claim checkpoints for pools
    mapping (PoolId _poolId => uint _amount) internal _totalFeeAllocation;

    /// Maps a FlaunchToken to a PoolId for simple lookups
    mapping (uint _internalId => PoolId _poolId) public tokenPoolId;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) TreasuryManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * Registers the tokenId passed by the initialization and ensures that it is the only one
     * registered to the manager. We also set our initial configurations, though the majority
     * of these can be updated by the owner at a later date.
     *
     * @param _owner Owner of the manager
     * @param _data Onboarding variables
     */
    function _initialize(address _owner, bytes calldata _data) internal override {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Validate the protocol fee that has been passed
        if (params.protocolFee > MAX_PROTOCOL_FEE) revert InvalidProtocolFee();

        // Set our protocol recipient
        protocolRecipient = params.protocolRecipient;
        emit ProtocolRecipientUpdated(protocolRecipient);

        // Set our protocol fee
        protocolFee = params.protocolFee;
        emit ProtocolFeeUpdated(protocolFee);

        emit ManagerInitialized(_owner, params);
    }

    /**
     * Handles a token being depositted into the manager.
     *
     * @param _flaunchToken The FlaunchToken being depositted
     * @param _creator The creator of the FlaunchToken
     * @param _data Additional deposit data for the manager
     */
    function _deposit(FlaunchToken calldata _flaunchToken, address _creator, bytes calldata _data) internal override {
        // Set the end-owner creator, ensuring that it is not a zero address
        if (_creator == address(0)) revert InvalidCreatorAddress();
        creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _creator;

        // Capture the current `totalFeeAllocation` of the provided token
        PoolId poolId = _flaunchToken.flaunch.poolId(_flaunchToken.tokenId);
        _totalFeeAllocation[poolId] = treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId);

        // Increment our internalId counter and set up our internal mappings
        ++_nextInternalId;

        internalIds[_nextInternalId] = _flaunchToken;
        flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _nextInternalId;
        _creatorTokens[_creator].add(_nextInternalId);

        // Map our PoolId for simple lookups
        tokenPoolId[_nextInternalId] = poolId;
    }

    /**
     * Helper function to show the next internalId that will be generated.
     *
     * @return The next internalId that will be assigned
     */
    function nextInternalId() public view returns (uint) {
        return _nextInternalId + 1;
    }

    /**
     * Returns an array of all FlaunchToken data assigned to the creator.
     *
     * @param _creator The creator to retrieve the FlaunchTokens for
     *
     * @return flaunchTokens_ The FlaunchTokens belonging to the _creator
     */
    function tokens(address _creator) public view returns (FlaunchToken[] memory flaunchTokens_) {
        uint creatorTokensLength = _creatorTokens[_creator].length();
        flaunchTokens_ = new FlaunchToken[](creatorTokensLength);
        for (uint i; i < creatorTokensLength; ++i) {
            // Convert the internalId to the FlaunchToken and pass to the claim function
            flaunchTokens_[i] = internalIds[_creatorTokens[_creator].at(i)];
        }
    }

    /**
     * Allows the caller to check the balance of their position. This will check all of the
     * creator's tokens, and if the protocol fee recipient calls this then it will also show
     * the amount available for them to claim.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient) public view returns (uint balance_) {
        // Get the fees for the manager
        uint managerFees = treasuryManagerFactory.feeEscrow().balances(address(this));

        // Get fees from positions held by the recepient
        for (uint i; i < _creatorTokens[_recipient].length(); ++i) {
            // Get the PoolId from the FlaunchToken, mapped from the internalId
            PoolId poolId = getPoolId(internalIds[_creatorTokens[_recipient].at(i)]);

            // Get the difference that the user can claim by finding the total fee allocation made
            // to this pool and reducing it by the cached internal total fee allocation.
            uint newTotalFeeAllocation = treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId) - _totalFeeAllocation[poolId];
            balance_ += newTotalFeeAllocation - getProtocolFee(newTotalFeeAllocation);
        }

        // If the recipient is the protocol fee recipient, then we provide the additional
        // fees that they can claim.
        if (_recipient == protocolRecipient) {
            balance_ += _protocolAvailableClaim + getProtocolFee(managerFees);
        }
    }

    /**
     * Allows a protocol owner to make a claim, without any additional {FlaunchToken} logic
     * being passed in the parameters.
     *
     * @return amount_ The amount of ETH claimed from fees
     */
    function claim() public virtual returns (uint amount_) {
        // Withdraw fees earned from the held ERC721s, unwrapping into ETH. This will update
        // the `_protocolAvailableClaim` variable in the `receive` function callback.
        treasuryManagerFactory.feeEscrow().withdrawFees(address(this), true);

        // Get all of the tokens held by the sender (the stored creator of the token)
        for (uint i; i < _creatorTokens[msg.sender].length(); ++i) {
            // Convert the internalId to the FlaunchToken and pass to the claim function
            amount_ += _creatorClaim(internalIds[_creatorTokens[msg.sender].at(i)]);
        }

        // Make our protocol claim if the sender is the `protocolRecipient`
        if (msg.sender == protocolRecipient) {
            amount_ += _protocolClaim();
        }

        // Transfer the ETH to the sender
        if (amount_ != 0) {
            (bool success,) = payable(msg.sender).call{value: amount_}('');
            if (!success) revert FailedToClaim();
        }
    }

    /**
     * Allows a creator to make claims against specific fee revenues they have earned.
     *
     * @param _flaunchToken An array of flaunch tokens to claim against
     *
     * @return amount_ The amount of ETH claimed from fees
     */
    function claim(FlaunchToken[] calldata _flaunchToken) public returns (uint amount_) {
        // Withdraw fees earned from the held ERC721s, unwrapping into ETH. This will update
        // the `_protocolAvailableClaim` variable in the `receive` function callback.
        treasuryManagerFactory.feeEscrow().withdrawFees(address(this), true);

        // Iterate over all FlaunchTokens passed to allow batch claims
        uint _flaunchTokenLength = _flaunchToken.length;
        for (uint i; i < _flaunchTokenLength; ++i) {
            amount_ += _creatorClaim(_flaunchToken[i]);
        }

        // Transfer the ETH to the creator
        if (amount_ != 0) {
            (bool success,) = payable(msg.sender).call{value: amount_}('');
            if (!success) revert FailedToClaim();
        }
    }

    /**
     * Makes a claim as the protocol to withdraw fees to the `protocolRecipient`.
     *
     * @return availableClaim_ The amount claimed by the protocol
     */
    function _protocolClaim() internal returns (uint availableClaim_) {
        // If we have nothing available to claim, exit early
        if (_protocolAvailableClaim == 0) {
            return 0;
        }

        // Reset the available claim amount to prevent reentrancy attacks
        availableClaim_ = _protocolAvailableClaim;
        _protocolAvailableClaim = 0;

        // Increase the total amount that the protocol recipient has claimed
        protocolTotalClaimed += availableClaim_;

        emit ProtocolRevenueClaimed(protocolRecipient, availableClaim_);
    }

    /**
     * Makes a claim as the creator to withdraw fees to their address.
     *
     * @param _flaunchToken The FlaunchToken being claimed against
     *
     * @return creatorAvailableClaim_ The amount claimed by the creator
     */
    function _creatorClaim(FlaunchToken memory _flaunchToken) internal returns (uint creatorAvailableClaim_) {
        // Validate that the `msg.sender` is the stored creator for the claim
        if (msg.sender != creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId]) {
            revert InvalidClaimer();
        }

        // Get the PoolId from the FlaunchToken
        PoolId poolId = getPoolId(_flaunchToken);

        // Get the difference that the user can claim by finding the total fee allocation made
        // to this pool and reducing it by the cached internal total fee allocation.
        uint newTotalFeeAllocation = treasuryManagerFactory.feeEscrow().totalFeesAllocated(poolId);
        creatorAvailableClaim_ = newTotalFeeAllocation - _totalFeeAllocation[poolId];

        // Update the cached total fee allocation
        _totalFeeAllocation[poolId] = newTotalFeeAllocation;

        // Remove the protocol fee from the available claim
        creatorAvailableClaim_ -= getProtocolFee(creatorAvailableClaim_);

        // If we have nothing available to claim, exit early
        if (creatorAvailableClaim_ == 0) {
            return 0;
        }

        // Increase the total amount that the creator has claimed
        creatorTotalClaimed[msg.sender] += creatorAvailableClaim_;
        tokenTotalClaimed[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] += creatorAvailableClaim_;

        emit RevenueClaimed(address(_flaunchToken.flaunch), _flaunchToken.tokenId, msg.sender, creatorAvailableClaim_);
    }

    /**
     * Allows the protocol recipient to be updated. This can allow a zero value that will
     * bypass the protocol recipient taking a protocol fee during the claim.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _protocolRecipient The new protocol recipient address
     */
    function setProtocolRecipient(address payable _protocolRecipient) public onlyManagerOwner {
        protocolRecipient = _protocolRecipient;
        emit ProtocolRecipientUpdated(_protocolRecipient);
    }

    /**
     * Allows the end-owner creator of the ERC721 to be updated by the intermediary platform. This
     * will change the recipient of fees that are earned from the token externally and can be used
     * for external validation of permissioned calls.
     *
     * @dev This can only be called by the `managerOwner`
     *
     * @param _flaunchToken The flaunch token whose creator is being updated
     * @param _creator The new end-owner creator address
     */
    function setCreator(FlaunchToken calldata _flaunchToken, address payable _creator) public onlyManagerOwner {
        // Ensure that the creator is not a zero address
        if (_creator == address(0)) {
            revert InvalidCreatorAddress();
        }

        // Map our flaunch token to the internalId
        uint internalId = flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];

        // If the internalId does not exist, then we cannot update the creator
        if (internalId == 0) {
            revert UnknownFlaunchToken();
        }

        // Find the old creator and update their enumerable set
        address currentCreator = creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];
        _creatorTokens[currentCreator].remove(internalId);

        // Update the pool creator and move the token into their enumerable set
        creator[address(_flaunchToken.flaunch)][_flaunchToken.tokenId] = _creator;
        _creatorTokens[_creator].add(internalId);

        emit CreatorUpdated(address(_flaunchToken.flaunch), _flaunchToken.tokenId, _creator);
    }

    /**
     * Calculates the protocol fee that will be taken from the amount passed in.
     *
     * @param _amount The amount to calculate the protocol fee from
     *
     * @return protocolFee_ The protocol fee to be taken from the amount
     */
    function getProtocolFee(uint _amount) public view returns (uint protocolFee_) {
        return (_amount * protocolFee + MAX_PROTOCOL_FEE - 1) / MAX_PROTOCOL_FEE;
    }

    /**
     * Maps a FlaunchToken to a PoolId.
     *
     * @param _flaunchToken The FlaunchToken to lookup
     *
     * @return poolId_ The corresponding PoolId
     */
    function getPoolId(FlaunchToken memory _flaunchToken) public view returns (PoolId poolId_) {
        // Find our internalId. If this cannot be found then we revert as it's an unknown token
        uint internalId = flaunchTokenInternalIds[address(_flaunchToken.flaunch)][_flaunchToken.tokenId];
        if (internalId == 0) {
            revert UnknownFlaunchToken();
        }

        poolId_ = tokenPoolId[internalId];
    }

    /**
     * When we receive ETH from a source other than fee withdrawal or flETH unwrapping, then
     * we need to add this to our totalClaimed amount. This allows us to receive ETH from
     * external sources that will also be distributed to our recipients.
     */
    receive () external override payable {
        _protocolAvailableClaim += getProtocolFee(msg.value);
    }

}
