// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {BaseFeeCalculator} from '@flaunch/fees/BaseFeeCalculator.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';


/**
 * This implementation of the {IFeeCalculator} just returns the same base swapFee that
 * is assigned in the FeeDistribution struct.
 */
contract StaticFeeCalculator is BaseFeeCalculator {

    using PoolIdLibrary for PoolKey;

    /**
     * Sets the native token and custom fee manager registry.
     *
     * @param _nativeToken The native token address used by the protocol
     * @param _customFeeManagerRegistry The custom fee manager registry address
     */
    constructor (address _nativeToken, address _customFeeManagerRegistry) BaseFeeCalculator(_nativeToken, _customFeeManagerRegistry) {}

    /**
     * For a static value we simply return the `_baseFee` that was passed in with no
     * additional multipliers or calculations.
     *
     * @param _baseFee The base swap fee
     *
     * @return swapFee_ The calculated swap fee to use
     */
    function _determineSwapFee(
        PoolKey memory /* _poolKey */,
        IPoolManager.SwapParams memory /* _params */,
        uint24 _baseFee
    ) internal pure override returns (uint24 swapFee_) {
        return _baseFee;
    }

    /**
     * Tracks information regarding ongoing swaps for pools. For post-fair launch swaps,
     * we need to verify that the fair launch verification was properly handled.
     *
     * @dev This function will only be called by the PositionManager if the fair launch
     * has ended.

     * @param _sender The address of the sender of the swap
     * @param _poolKey The pool key of the pool that was swapped
     * @param _params The parameters of the swap
     * @param _delta The balance delta of the swap
     * @param _hookData The hook data of the swap
     */
    function _trackSwap(
        address _sender,
        PoolKey calldata _poolKey,
        IPoolManager.SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) internal override {
        // If the fair launch ended at the same timestamp as the current block, we need to
        // verify the transaction using the fair launch calculator.
        if (_isInFairLaunch(msg.sender, _poolKey.toId())) {
            // Get the Fair Launch calculator from the PositionManager
            IFeeCalculator fairLaunchCalculator = IPositionManager(msg.sender).getFeeCalculator(true);
            
            // Call trackSwap against this calculator with the same parameters to ensure 
            // that we pass verifications.
            if (address(fairLaunchCalculator) != address(0) && address(fairLaunchCalculator) != address(this)) {
                fairLaunchCalculator.trackSwap(_sender, _poolKey, _params, _delta, _hookData);
            }
        }
    }

}
