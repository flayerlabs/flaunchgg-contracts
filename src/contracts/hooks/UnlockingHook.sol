// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';

import {BaseHook} from '@uniswap-hooks/base/BaseHook.sol';

/**
 * Extends {BaseHook} with the {SafeCallback}-style unlock-callback wrapper. We cannot
 * inherit {SafeCallback} directly because both it and {BaseHook} derive from
 * {ImmutableState} and each constructor passes the {IPoolManager} to it, producing a
 * "Base constructor arguments given twice" diamond error.
 */
abstract contract UnlockingHook is BaseHook, IUnlockCallback {
    constructor(
        IPoolManager _poolManager
    ) BaseHook(_poolManager) {}

    /**
     * External entry point invoked by the {PoolManager} during `unlock`. Reverts unless
     * the caller is the registered pool manager; otherwise dispatches to the subclass
     * implementation of {_unlockCallback}.
     */
    function unlockCallback(
        bytes calldata _data
    ) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        return _unlockCallback(_data);
    }

    function _unlockCallback(
        bytes calldata _data
    ) internal virtual returns (bytes memory);
}
