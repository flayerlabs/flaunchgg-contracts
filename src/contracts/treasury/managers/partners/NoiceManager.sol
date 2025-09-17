// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

import {RevenueManager} from '@flaunch/treasury/managers/RevenueManager.sol';
import {ICustomFeeManager} from '@flaunch-interfaces/ICustomFeeManager.sol';


/**
 * A custom fee implementation used for the NOICE protocol. This overwrites the default swap fee calculation to
 * instead return 2%. During the traditional fair launch period we also bypass the native logic to instead
 * implement  a linearly degrading curve, starting from when the fair launch started (80% fee) and ending at a
 * set time duration (2% fee).
 *
 * @dev The protocol recipient can be updated by the manager owner by calling the `setProtocolRecipient` function.
 */
contract NoiceManager is ICustomFeeManager, RevenueManager {

    using EnumerableSet for EnumerableSet.UintSet;

    uint24 public constant BASE_FEE = 2_0000;  // 2%
    uint24 public constant FAIR_LAUNCH_START_FEE = 80_0000;  // 80%

    /**
     * Sets up the contract with the initial required contract addresses.
     *
     * @param _treasuryManagerFactory The {TreasuryManagerFactory} that will launch this implementation
     */
    constructor (address _treasuryManagerFactory) RevenueManager(_treasuryManagerFactory) {
        // ..
    }

    /**
     * For a static value we simply return the `_baseFee` that was passed in with no additional multipliers
     * or calculations. If we are in fair launch, we want to determine the fee based on a linearly degrading
     * curve, starting from when the fair launch started and ending at a set time duration.
     *
     * @param _poolKey The pool key
     * @param _baseFee The base swap fee
     *
     * @return swapFee_ The calculated swap fee to use
     */
    function determineSwapFee(
        PoolKey memory _poolKey,
        IPoolManager.SwapParams memory /* _params */,
        uint24 _baseFee
    ) public view override returns (uint24 swapFee_) {
        // If we are in fair launch, we want to determine the fee based on a linearly degrading curve, starting
        // from when the fair launch started and ending at a set time duration.
        FairLaunch.FairLaunchInfo memory info = IPositionManager(address(_poolKey.hooks)).fairLaunch().fairLaunchInfo(_poolKey.toId());
        if (block.timestamp >= info.startsAt && block.timestamp < info.endsAt) {
            // Linearly degrade the fee from FAIR_LAUNCH_START_FEE to BASE_FEE over the fair launch duration
            uint duration = info.endsAt - info.startsAt;
            uint elapsed = block.timestamp - info.startsAt;
            uint24 feeDelta = FAIR_LAUNCH_START_FEE - BASE_FEE;
        
            return uint24(FAIR_LAUNCH_START_FEE - (feeDelta * elapsed / duration));
        }

        return BASE_FEE;
    }

    /**
     * We bypass the track swap logic by implementing an empty function, meaning that we can effectively
     * bypass the fair launch verification logic.
     *
     * @return bypassNative_ Whether to bypass the native logic
     */
    function trackSwap(
        address /* _sender */,
        PoolKey memory /* _poolKey */,
        IPoolManager.SwapParams memory /* _params */,
        BalanceDelta /* _delta */,
        bytes calldata /* _hookData */
    ) public override returns (bool bypassNative_) {
        // We bypass the native logic
        bypassNative_ = true;
    }

    /**
     * Allows the owner to make a claim on behalf of the external fee recipient. Creators can also claim without any
     additional {FlaunchToken} logic being passed in the parameters.
     *
     * @return amount_ The amount of ETH claimed from fees
     */
    function claim() public override returns (uint amount_) {
        // If we are claiming as the manager owner, then we want to make the claim on behalf of the external fee recipient
        address msgSender = msg.sender;
        if (msgSender == managerOwner) {
            msgSender = protocolRecipient;
        }

        // Withdraw fees earned from the held ERC721s, unwrapping into ETH. This will update
        // the `_protocolAvailableClaim` variable in the `receive` function callback.
        treasuryManagerFactory.feeEscrow().withdrawFees(address(this), true);

        // Get all of the tokens held by the sender (the stored creator of the token)
        for (uint i; i < _creatorTokens[msgSender].length(); ++i) {
            // Convert the internalId to the FlaunchToken and pass to the claim function
            amount_ += _creatorClaim(internalIds[_creatorTokens[msgSender].at(i)]);
        }

        // Make our protocol claim if the sender is the `protocolRecipient`
        if (msgSender == protocolRecipient) {
            amount_ += _protocolClaim();
        }

        // Transfer the ETH to the sender
        if (amount_ != 0) {
            (bool success,) = payable(msgSender).call{value: amount_}('');
            if (!success) revert FailedToClaim();
        }
    }

}
