// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';

/**
 * This implementation of the {IFeeCalculator} just returns the same base swapFee that
 * is assinged in the FeeDistribution struct.
 */
contract StaticFeeCalculator is IFeeCalculator {
    /**
     * For a static value we simply return the `_baseFee` that was passed in with no
     * additional multipliers or calculations.
     *
     * @param _baseFee The base fee
     *
     * @return swapFee_ The swap fee
     */
    function determineSwapFee(
        PoolKey memory,
        SwapParams memory,
        uint24 _baseFee
    ) public pure returns (uint24 swapFee_) {
        return _baseFee;
    }

    /**
     * Noops the swap tracking function.
     */
    function trackSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) public pure {
        // ..
    }

    /**
     * Noops the flaunch params setting function.
     */
    function setFlaunchParams(
        PoolId,
        bytes calldata
    ) external override {
        // ..
    }
}
