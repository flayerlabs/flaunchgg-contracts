// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

interface IFeeCalculator {
    function determineSwapFee(
        PoolKey memory _poolKey,
        SwapParams memory _params,
        uint24 _baseFee
    ) external view returns (uint24 swapFee_);

    function trackSwap(
        address _sender,
        PoolKey calldata _poolKey,
        SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) external;

    function setFlaunchParams(
        PoolId _poolId,
        bytes calldata _params
    ) external;
}
