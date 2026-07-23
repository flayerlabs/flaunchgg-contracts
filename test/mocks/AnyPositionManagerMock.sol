// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';

contract AnyPositionManagerMock is AnyPositionManager {
    constructor(
        ConstructorParams memory params
    ) AnyPositionManager(params) {
        // ..
    }

    function depositFeesMock(
        PoolKey memory key,
        uint amount0,
        uint amount1
    ) external {
        internalSwapPool.depositFees(key, amount0, amount1);
    }

    function distributeFeesMock(
        PoolKey memory _poolKey
    ) external {
        _distributeFees(_poolKey);
    }

    function captureDelta(
        SwapParams memory _params,
        BeforeSwapDelta _delta
    ) external returns (int amount0_, int amount1_) {
        _captureDelta(_params, TS_FL_AMOUNT0, TS_FL_AMOUNT1, _delta);
        return (_tload(TS_FL_AMOUNT0), _tload(TS_FL_AMOUNT1));
    }

    function captureDeltaSwapFee(
        SwapParams memory _params,
        uint _delta
    ) external returns (int amount0_, int amount1_) {
        _captureDeltaSwapFee(_params, TS_FL_FEE0, TS_FL_FEE1, _delta);
        return (_tload(TS_FL_FEE0), _tload(TS_FL_FEE1));
    }

    function emitPoolStateUpdate(
        PoolId _poolId
    ) external {
        _emitPoolStateUpdate(_poolId, '', '');
    }
}
