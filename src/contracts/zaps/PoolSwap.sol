// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IUnlockCallback} from '@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TransientStateLibrary} from '@uniswap/v4-core/src/libraries/TransientStateLibrary.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';

/**
 * Handles swaps against Uniswap V4 pools.
 *
 * @dev Copied from the `v4-core` `PoolSwapTest.sol` contract and simplified to suit Flaunch
 * requirements.
 */
contract PoolSwap is IUnlockCallback {
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using TransientStateLibrary for IPoolManager;

    /**
     * Stores information to be passed back when unlocking the callback.
     *
     * @member sender The sender of the swap
     * @member key The poolKey being swapped against
     * @member params Swap parameters
     * @member hookData Arbitrary data passed to the pool's hook
     */
    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    /// The Uniswap V4 {PoolManager} contract
    IPoolManager public immutable manager;

    /**
     * Register our Uniswap V4 {PoolManager}.
     *
     * @param _manager The Uniswap V4 {PoolManager}
     */
    constructor(
        IPoolManager _manager
    ) {
        manager = _manager;
    }

    /**
     * Actions a swap using the SwapParams provided against the PoolKey without a referrer.
     *
     * @param _key The PoolKey to swap against
     * @param _params The parameters for the swap
     *
     * @return The BalanceDelta of the swap
     */
    function swap(
        PoolKey memory _key,
        SwapParams memory _params
    ) public payable virtual returns (BalanceDelta) {
        return swap(_key, _params, address(0));
    }

    /**
     * Actions a swap using the SwapParams provided against the PoolKey with a referrer.
     *
     * @param _key The PoolKey to swap against
     * @param _params The parameters for the swap
     * @param _referrer The referrer of the swap
     *
     * @return delta_ The BalanceDelta of the swap
     */
    function swap(
        PoolKey memory _key,
        SwapParams memory _params,
        address _referrer
    ) public payable virtual returns (BalanceDelta delta_) {
        delta_ = abi.decode(
            manager.unlock(
                abi.encode(CallbackData(msg.sender, _key, _params, _referrer == address(0) ? bytes('') : abi.encode(_referrer)))
            ),
            (BalanceDelta)
        );
    }

    /**
     * Actions a swap using the SwapParams provided against the PoolKey with hook data.
     *
     * @param _key The PoolKey to swap against
     * @param _params The parameters for the swap
     * @param _hookData Arbitrary data passed to the pool's hook
     *
     * @return delta_ The BalanceDelta of the swap
     */
    function swap(
        PoolKey memory _key,
        SwapParams memory _params,
        bytes memory _hookData
    ) public payable virtual returns (BalanceDelta delta_) {
        delta_ = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, _key, _params, _hookData))), (BalanceDelta));
    }

    /**
     * Performs the swap call using information from the CallbackData.
     */
    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        // Ensure that the {PoolManager} has sent the message
        require(msg.sender == address(manager));

        // Decode our CallbackData
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        int deltaBefore0 = manager.currencyDelta(address(this), data.key.currency0);
        int deltaBefore1 = manager.currencyDelta(address(this), data.key.currency1);

        require(deltaBefore0 == 0, 'deltaBefore0 is not equal to 0');
        require(deltaBefore1 == 0, 'deltaBefore1 is not equal to 0');

        // Action the swap
        BalanceDelta delta = manager.swap({key: data.key, params: data.params, hookData: data.hookData});

        int deltaAfter0 = manager.currencyDelta(address(this), data.key.currency0);
        int deltaAfter1 = manager.currencyDelta(address(this), data.key.currency1);

        // Sense checking of the request for safety
        if (data.params.zeroForOne) {
            if (data.params.amountSpecified < 0) {
                // exact input, 0 for 1
                require(
                    deltaAfter0 >= data.params.amountSpecified, 'deltaAfter0 is not greater than or equal to data.params.amountSpecified'
                );
                require(delta.amount0() == deltaAfter0, 'delta.amount0() is not equal to deltaAfter0');
                require(deltaAfter1 >= 0, 'deltaAfter1 is not greater than or equal to 0');
            } else {
                // exact output, 0 for 1
                require(deltaAfter0 <= 0, 'deltaAfter0 is not less than or equal to zero');
                require(delta.amount1() == deltaAfter1, 'delta.amount1() is not equal to deltaAfter1');
                require(deltaAfter1 <= data.params.amountSpecified, 'deltaAfter1 is not less than or equal to data.params.amountSpecified');
            }
        } else {
            if (data.params.amountSpecified < 0) {
                // exact input, 1 for 0
                require(
                    deltaAfter1 >= data.params.amountSpecified, 'deltaAfter1 is not greater than or equal to data.params.amountSpecified'
                );
                require(delta.amount1() == deltaAfter1, 'delta.amount1() is not equal to deltaAfter1');
                require(deltaAfter0 >= 0, 'deltaAfter0 is not greater than or equal to 0');
            } else {
                // exact output, 1 for 0
                require(deltaAfter1 <= 0, 'deltaAfter1 is not less than or equal to 0');
                require(delta.amount0() == deltaAfter0, 'delta.amount0() is not equal to deltaAfter0');
                require(deltaAfter0 <= data.params.amountSpecified, 'deltaAfter0 is not less than or equal to data.params.amountSpecified');
            }
        }

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(manager, data.sender, uint(-deltaAfter0), false);
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(manager, data.sender, uint(-deltaAfter1), false);
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(manager, data.sender, uint(deltaAfter0), false);
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(manager, data.sender, uint(deltaAfter1), false);
        }

        return abi.encode(delta);
    }
}
