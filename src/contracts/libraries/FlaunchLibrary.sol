// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';

/**
 * Shared launch-time math and liquidity helpers used by the {PositionManager} when seeding a
 * freshly flaunched pool and filling a premine.
 *
 * @dev These functions are `public` so the library is deployed separately and linked into the
 * {PositionManager} via `delegatecall`, keeping their (sizeable) runtime bytecode out of the hook
 * contract, which sits close to the EIP-170 limit. Because calls are delegated, `address(this)`
 * inside {createImmutablePosition} resolves to the calling {PositionManager}, so settlement is paid
 * from its balances exactly as if the logic were inlined.
 */
library FlaunchLibrary {
    using CurrencySettler for Currency;
    using TickFinder for int24;

    /**
     * Resolves the tick ranges for the two single-sided launch positions, placing the ETH position
     * in a tight band adjacent to the launch tick and the memecoin position spanning outward.
     *
     * @param _initialTick The tick the pool was initialized at
     * @param _nativeIsZero Whether the native token is `currency0`
     */
    function launchTickRanges(
        int24 _initialTick,
        bool _nativeIsZero
    ) public pure returns (int24 ethTickLower_, int24 ethTickUpper_, int24 memeTickLower_, int24 memeTickUpper_) {
        if (_nativeIsZero) {
            ethTickLower_ = (_initialTick + 1).validTick(false);
            ethTickUpper_ = ethTickLower_ + TickFinder.TICK_SPACING;

            memeTickLower_ = TickFinder.MIN_TICK;
            memeTickUpper_ = (_initialTick - 1).validTick(true);
        } else {
            ethTickUpper_ = (_initialTick - 1).validTick(true);
            ethTickLower_ = ethTickUpper_ - TickFinder.TICK_SPACING;

            memeTickLower_ = (_initialTick + 1).validTick(false);
            memeTickUpper_ = TickFinder.MAX_TICK;
        }
    }

    /**
     * Creates an immutable, single-sided position, settling the required tokens from the calling
     * contract's balance. Adapted from the (removed) FairLaunch position logic.
     *
     * @param _poolManager The Uniswap V4 {PoolManager}
     * @param _poolKey The PoolKey to create a position against
     * @param _tickLower The lower tick of the position
     * @param _tickUpper The upper tick of the position
     * @param _tokens The number of tokens to put into the position
     * @param _tokenIsZero True if the position is created with `currency0`; false for `currency1`
     */
    function createImmutablePosition(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint _tokens,
        bool _tokenIsZero
    ) public {
        uint128 liquidityDelta = _tokenIsZero
            ? LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
                amount0: _tokens
            })
            : LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
                amount1: _tokens
            });

        // If we have no liquidity, then exit before creating the position which would revert
        if (liquidityDelta == 0) {
            return;
        }

        (BalanceDelta delta,) = _poolManager.modifyLiquidity({
            key: _poolKey,
            params: ModifyLiquidityParams({tickLower: _tickLower, tickUpper: _tickUpper, liquidityDelta: int128(liquidityDelta), salt: ''}),
            hookData: ''
        });

        // Settle the tokens that are required to fill the position
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(_poolManager, address(this), uint(-int(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            _poolKey.currency1.settle(_poolManager, address(this), uint(-int(delta.amount1())), false);
        }
    }
}
