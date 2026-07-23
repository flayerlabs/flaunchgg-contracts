// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

interface IInternalSwapPool {
    /// Emitted when a pool has been allocated fees on either side of the position
    event PoolFeesReceived(PoolId indexed _poolId, uint _amount0, uint _amount1);

    /// Emitted when pool fees have been internally swapped
    event PoolFeesSwapped(PoolId indexed _poolId, bool zeroForOne, uint _amount0, uint _amount1);

    /**
     * Contains amounts for both the currency0 and currency1 values of a UV4 Pool.
     */
    struct ClaimableFees {
        uint amount0;
        uint amount1;
    }

    function poolFees(
        PoolKey memory _poolKey
    ) external view returns (ClaimableFees memory);

    function depositFees(
        PoolKey memory _poolKey,
        uint _amount0,
        uint _amount1
    ) external;

    function resetNativeFees(
        PoolId _poolId
    ) external returns (uint amount0_);

    function internalSwap(
        PoolKey calldata _key,
        SwapParams memory _params,
        bool _nativeIsZero
    ) external returns (uint ethIn_, uint tokenOut_);
}
