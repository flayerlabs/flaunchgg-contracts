// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';


/**
 * Takes fees from the tokens within it and then routes claimable balance into the BidWall
 * of a defined Flaunch token's PoolKey. We are required to use `unlockCallback` against
 * the Uniswap V4 {PoolManager} to deposit the fees into the BidWall contract.
 *
 * @dev Anyone is able to trigger the claim for the manager itself.
 */
contract BuyBackManager is FeeSplitManager, IUnlockCallback {

    using EnumerableSet for EnumerableSet.UintSet;
    using StateLibrary for PoolManager;

    error InvalidCaller();
    error InvalidImplementation();
    error InvalidPoolKey();

    event BidWallDeposit(uint _ethAmount);
    event ManagerInitialized(address _owner, InitializeParams _params);
    event RevenueClaimed(address indexed _recipient, uint _amountClaimed);

    /**
     * Parameters passed during manager initialization.
     *
     * @member creatorShare The share that a creator will earn from their token
     * @member ownerShare The share that the manager owner will earn from their token
     * @member buyBackPoolKey The Flaunch PoolKey that will receive BidWall deposits
     */
    struct InitializeParams {
        uint creatorShare;
        uint ownerShare;
        PoolKey buyBackPoolKey;
    }

    /**
     * Stores information to be passed back when unlocking the callback.
     *
     * @member poolKey The Flaunch PoolKey to deposit into
     * @member ethAmount The amount of ETH to deposit into BidWall
     */
    struct CallbackData {
        PoolKey poolKey;
        uint ethAmount;
    }

    /// Stores the address of the initial {BuyBackManager} implementation contract
    address payable public immutable buyBackContract;

    /// Stores the address of the Uniswap V4 {PoolManager}
    PoolManager public immutable poolManager;

    /// Stores the address of the BidWall contract
    BidWall public immutable bidWall;

    /// Stores the address of the flETH token
    Currency public immutable flETH;

    /// Stores the PoolKey to buy back via the manager
    PoolKey public buyBackPoolKey;

    /// Store the balance after last withdraw by the manager
    uint internal _lastWithdrawBalance;

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     * @param _poolManager The Uniswap V4 {PoolManager}
     * @param _bidWall The BidWall contract
     * @param _flETH The flETH token
     */
    constructor (address _treasuryManagerFactory, address _poolManager, address _bidWall, address _flETH) FeeSplitManager(_treasuryManagerFactory) {
        buyBackContract = payable(address(this));
        poolManager = PoolManager(_poolManager);
        bidWall = BidWall(_bidWall);
        flETH = Currency.wrap(_flETH);
    }

    /**
     * Registers the creator and owner shares, and sets the Flaunch PoolKey that will
     * receive the BidWall deposits.
     *
     * @param _owner The owner of the manager
     * @param _data The initialization variables
     */
    function _initialize(address _owner, bytes calldata _data) internal override {
        // Unpack our initial manager settings
        (InitializeParams memory params) = abi.decode(_data, (InitializeParams));

        // Validate and set our creator and owner shares
        _setShares(params.creatorShare, params.ownerShare);

        // Set our buyBackPoolKey
        buyBackPoolKey = params.buyBackPoolKey;
        _validatePoolKey(buyBackPoolKey);

        // We emit our initialization event first, as the subgraph may need this information
        // indexed before we emit recipient share events.
        emit ManagerInitialized(_owner, params);
    }

    /**
     * Finds the ETH balance that is claimable by the `_recipient`.
     *
     * @param _recipient The account to find the balance of
     *
     * @return balance_ The amount of ETH available to claim by the `_recipient`
     */
    function balances(address _recipient) public view override returns (uint balance_) {
        (uint creatorBalance, uint ownerBalance) = _balances(_recipient);
        balance_ = creatorBalance + ownerBalance;
    }

    /**
     * Finds a breakdown of balances available to the recipient by taking into account their
     * creator and owner shares.
     *
     * @param _recipient The account to find the balances of
     *
     * @return creatorBalance_ The balance available from creator fees
     * @return ownerBalance_ The balance available from owner fees
     */
    function _balances(address _recipient) internal view returns (uint creatorBalance_, uint ownerBalance_) {
        // We then need to check if the `_recipient` is the creator of any tokens, and if they
        // are then we need to find out the available amounts to claim.
        creatorBalance_ = pendingCreatorFees(_recipient);

        // We then need to check if the `_recipient` is the owner of the manager, and if they
        // are then we need to find out the available amounts to claim.
        if (_recipient == managerOwner) {
            ownerBalance_ = claimableOwnerFees();
        }
    }

    /**
     * Allows for a claim call to be made without requiring any additional requirements for
     * bytes to be passed, as these would always be unused for this FeeSplit Manager.
     *
     * @return uint The amount claimed from the call
     */
    function claim() public returns (uint) {
        return _claim(abi.encode(''));
    }

    /**
     * Checks if the `_recipient` is the creator of any tokens in the manager, or if they are the
     * owner of the manager.
     *
     * @param _recipient The recipient address to check against
     * @param _data No additional data is required
     *
     * @return bool If the recipient is valid to receive an allocation
     */
    function isValidRecipient(address _recipient, bytes memory _data) public view override returns (bool) {
        return _creatorTokens[_recipient].length() != 0 || _recipient == managerOwner;
    }

    /**
     * This function calculates the allocation that the recipient is owed, and also registers the
     * claim within the manager to offset against future claims.
     *
     * @dev The `_recipient` is set to be the initial `msg.sender`
     *
     * @param _recipient The recipient address to claim against
     * @param _data No additional data is required
     *
     * @return allocation_ The allocation claimed by the user
     */
    function _captureClaim(address _recipient, bytes memory _data) internal override returns (uint allocation_) {
        // Get our share balance
        (uint creatorBalance, uint ownerBalance) = _balances(_recipient);

        // If the recipient has a creator balance to claim, then action the claim against their
        // tokens and then increase their allocation by the balance.
        if (creatorBalance != 0) {
            // Iterate over the tokens that the user created to register the claim
            for (uint i; i < _creatorTokens[_recipient].length(); ++i) {
                _creatorClaim(internalIds[_creatorTokens[_recipient].at(i)]);
            }

            allocation_ += creatorBalance;
        }

        // If the recipient has an owner balance to claim, then action the claim against their
        // owner share and then increase their allocation by the balance.
        if (ownerBalance != 0) {
            _claimedOwnerFees += ownerBalance;
            allocation_ += ownerBalance;
        }

        emit RevenueClaimed(_recipient, allocation_);
    }

    /**
     * Transfers the revenue fee allocation (ETH) to the recipient.
     *
     * @param _recipient The recipient address to claim against
     * @param _allocation The total fees allocated to the recipient
     * @param _data No additional data is required
     */
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory _data) internal override {
        // Send the ETH fees to the recipient
        (bool success, bytes memory data) = payable(_recipient).call{value: _allocation}('');
        if (!success) {
            revert UnableToSendRevenue(data);
        }
    }

    /**
     * Validates that the PoolKey is valid for a Flaunch pool.
     *
     * @dev If the pool has been initialized and the hooks address is correct, then we can assume
     * safely that it is a valid Flaunch pool.
     *
     * @param _poolKey The PoolKey to validate
     *
     * @return nativeIsZero_ Whether the pool is using flETH as the currency0
     */
    function _validatePoolKey(PoolKey memory _poolKey) internal view returns (bool nativeIsZero_) {
        // Validate our PoolKey to ensure that it has been initialized against the PoolManager
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        if (sqrtPriceX96 == 0) {
            revert InvalidPoolKey();
        }

        // Ensure that the hooks contract is a recognized PositionManager
        if (!bidWall.hasRole(ProtocolRoles.POSITION_MANAGER, address(_poolKey.hooks))) {
            revert InvalidPoolKey();
        }

        // Return the nativeIsZero value
        nativeIsZero_ = _poolKey.currency0 == flETH;
    }

    /**
     * Routes any ETH allocated to the manager into the BidWall contract's position for the
     * defined Flaunch PoolKey.
     *
     * @return availableFees_ The amount of ETH that has been routed to the BidWall contract
     */
    function routeBuyBack() public nonReentrant returns (uint availableFees_) {
        // Route our buy back against the original, approved implementation
        if (address(this) == buyBackContract) {
            revert InvalidImplementation();
        }

        // Withdraw the fees for the manager. The amounts are captured inside of `creatorFees` and
        // `splitFees` from the {FeeSplitManager} contract.
        treasuryManagerFactory.feeEscrow().withdrawFees(address(this), true);

        // Check if we have fees available, calculated in our `receive` function
        availableFees_ = managerFees() - _lastWithdrawBalance;

        // Early return if there are no fees to distribute
        if (availableFees_ == 0) {
            return 0;
        }

        // Update the last claimed amount
        _lastWithdrawBalance = availableFees_;

        // Route the buy back against the original implementation
        BuyBackManager(buyBackContract).buyBack{value: availableFees_}(buyBackPoolKey);
    }

    /**
     * This function is called by the original implementation of the {BuyBackManager} to route
     * the fees into the BidWall contract.
     *
     * @param _buyBackPoolKey The PoolKey to buy back against
     */
    function buyBack(PoolKey memory _buyBackPoolKey) public payable {
        // Ensure that this contract being called is the original implementation
        if (address(this) != buyBackContract) {
            revert InvalidImplementation();
        }

        // Ensure that the caller is a deployed implementation of the {BuyBackManager}
        if (treasuryManagerFactory.managerImplementation(msg.sender) != address(this)) {
            revert InvalidImplementation();
        }

        // If we have not been passed any ETH in the call, then we need to revert
        if (msg.value == 0) {
            revert InvalidImplementation();
        }

        // Wrap the `msg.value` into the flETH token and approve the BidWall to spend it
        IFLETH(Currency.unwrap(flETH)).deposit{value: msg.value}(0);
        IFLETH(Currency.unwrap(flETH)).transfer(address(_buyBackPoolKey.hooks), msg.value);

        // Use the unlock pattern to get a lock from the PoolManager
        poolManager.unlock(abi.encode(CallbackData(_buyBackPoolKey, msg.value)));
    }

    /**
     * Performs the BidWall deposit using information from the CallbackData.
     */
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        // Ensure that the {PoolManager} has sent the message
        if (msg.sender != address(poolManager)) {
            revert InvalidCaller();
        }

        // Decode our CallbackData
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        // Get the current tick of the pool
        (, int24 currentTick,,) = poolManager.getSlot0(data.poolKey.toId());

        // Deposit the fees into the BidWall contract
        bidWall.deposit({
            _poolKey: data.poolKey,
            _ethSwapAmount: data.ethAmount,
            _currentTick: currentTick,
            _nativeIsZero: _validatePoolKey(data.poolKey)
        });

        emit BidWallDeposit(data.ethAmount);

        // Return an empty bytes array
        return abi.encode();
    }

}
