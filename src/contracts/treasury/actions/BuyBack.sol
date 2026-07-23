// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCastLib} from '@solady/utils/SafeCastLib.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Spends native token to buy non-native tokens from the pool.
 */
contract BuyBackAction is ITreasuryAction {
    using SafeCastLib for uint;

    /// The native token used by the Flaunch {PositionManager}
    Currency public immutable nativeToken;

    /// The PoolSwap contract to be used for the buy-back swap
    PoolSwap public immutable poolSwap;

    /**
     * Sets the native token used by the Flaunch {PositionManager}
     *
     * @param _nativeToken The ERC20 native token
     * @param _poolSwap The PoolSwap contract to action the buy-back swaps
     */
    constructor(
        address _nativeToken,
        address _poolSwap
    ) {
        nativeToken = Currency.wrap(_nativeToken);
        poolSwap = PoolSwap(_poolSwap);
    }

    /**
     * Implement the execute function to burn non-native tokens. Takes the caller's native-token
     * balance, swaps it through the {PoolSwap}, and returns only the per-call delta back to the
     * caller. Residuals from prior partial-fills (e.g. when a tight `sqrtPriceLimitX96` stops the
     * swap short) stay parked on this contract rather than leaking to the next caller.
     *
     * @param _poolKey The PoolKey to execute against
     * @param _data `uint160` encoded `sqrtPriceLimitX96`
     */
    function execute(
        PoolKey memory _poolKey,
        bytes memory _data
    ) external override {
        // Capture the amount of native token held by the sender
        uint amountSpecified = nativeToken.balanceOf(msg.sender);
        if (amountSpecified == 0) {
            return;
        }

        // Decode the `sqrtPriceLimitX96` from our `_data`
        (uint160 sqrtPriceLimitX96) = abi.decode(_data, (uint160));

        // [F-2] Snapshot pre-call balances so we only forward back what THIS call moved through
        // the contract. Without this, a partial-fill residual (e.g. unspent native when the
        // sqrtPriceLimit stops the swap short) left by an earlier caller would be swept by the
        // next caller — value bleeding between unrelated treasuries.
        uint before0 = _poolKey.currency0.balanceOf(address(this));
        uint before1 = _poolKey.currency1.balanceOf(address(this));

        // Pull in tokens from the caller and approve the swap contract to use them
        IMemecoin memecoin = IMemecoin(Currency.unwrap(nativeToken));
        memecoin.transferFrom(msg.sender, address(this), amountSpecified);
        memecoin.approve(address(poolSwap), amountSpecified);

        // Action our swap against the {PoolSwap} contract
        BalanceDelta delta = poolSwap.swap({
            _key: _poolKey,
            _params: SwapParams({
                zeroForOne: nativeToken == _poolKey.currency0,
                amountSpecified: -amountSpecified.toInt256(),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        });

        // Forward only the delta this call produced to the caller; any residual stays parked
        uint after0 = _poolKey.currency0.balanceOf(address(this));
        uint after1 = _poolKey.currency1.balanceOf(address(this));
        if (after0 > before0) {
            _poolKey.currency0.transfer(msg.sender, after0 - before0);
        }
        if (after1 > before1) {
            _poolKey.currency1.transfer(msg.sender, after1 - before1);
        }

        emit ActionExecuted(_poolKey, delta.amount0(), delta.amount1());
    }
}
