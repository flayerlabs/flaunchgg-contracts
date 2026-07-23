// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {ERC20Mock} from 'test/tokens/ERC20Mock.sol';

import {InternalSwapPoolHarness} from '../hooks/InternalSwapPool.t.sol';
import {FlaunchTest} from '../FlaunchTest.sol';
import {IInternalSwapPool} from '@flaunch-interfaces/IInternalSwapPool.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

/**
 * Regression coverage for audit finding F-10.
 *
 * The {InternalSwapPool} exact-output branch priced `sqrtPriceCurrentX96` at the manipulation-
 * resistant TWAP but still passed the user's raw `sqrtPriceLimitX96` as `sqrtPriceTargetX96`.
 * `SwapMath.computeSwapStep` infers direction from `current >= target`, so once the TWAP diverges
 * past the user's limit the inferred direction flips: the `(ethIn, tokenOut)` roles get swapped and
 * `pendingPoolFees.amount1 -= tokenOut_` underflows (DoS), or the fill settles the wrong way round.
 *
 * The fix pins `sqrtPriceTargetX96` to the matching price extreme (as the exact-input branch always
 * did). This test constructs the exact scenario the finding describes — a diverged 10-min TWAP with
 * a real slippage limit sitting between TWAP and spot — and asserts the fill neither reverts nor
 * mis-fills: native in, memecoin out, priced from the TWAP.
 */
contract F10IspExactOutputDivergedTwapTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    /// The exact-output inventory used by the fill (also the amount requested out).
    uint internal constant INVENTORY = 1 ether;

    address internal memecoin;

    function setUp() public {
        _deployPlatform();

        memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Full-range liquidity + a +3600s warp so the oracle has elapsed history to average over.
        _addLiquidityToPool(memecoin, int(10 ether), false);
    }

    function test_F10_ExactOutputFillWithDivergedTwapDoesNotRevertOrMisfill() public {
        PoolKey memory poolKey = positionManager.poolKey(memecoin);
        PoolId poolId = poolKey.toId();
        bool nativeIsZero = Currency.unwrap(poolKey.currency0) == address(flETH);
        uint160 targetExtreme = nativeIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // The tick recorded into the oracle at flaunch (nothing has moved spot yet).
        (, int24 genesisTick,,) = poolManager.getSlot0(poolId);

        // Diverge the 10-min TWAP from spot: sell memecoin into the pool to shove spot away from
        // the recorded tick. The swap records an observation at the (still-genesis) pre-swap tick,
        // so the TWAP stays anchored to the genesis tick while spot moves.
        _swap(poolKey, !nativeIsZero, 200 ether);

        int24 spotTick;
        (, spotTick,,) = poolManager.getSlot0(poolId);
        int24 twap = oracle.twapTick(poolId, spotTick);
        assertEq(twap, genesisTick, 'twap must stay anchored to the recorded observation');
        assertTrue(spotTick != genesisTick, 'spot did not move');

        // A real slippage limit sitting strictly between the (diverged) TWAP and spot. Precondition:
        // this is precisely the pre-fix-breaking case — using the user's limit as the
        // `computeSwapStep` target (pre-fix) infers a DIFFERENT direction than the correct extreme
        // target (post-fix), which is what swapped the roles / underflowed `amount1`.
        uint160 limit = TickMath.getSqrtPriceAtTick((genesisTick + spotTick) / 2);
        uint160 twapSqrt = TickMath.getSqrtPriceAtTick(twap);
        assertTrue(
            (twapSqrt >= limit) != (twapSqrt >= targetExtreme), 'test setup: limit does not straddle the TWAP direction'
        );

        // Drive the exact-output buy through a harness that shares the live oracle + pool state.
        // Post-fix this returns cleanly; pre-fix it reverted (amount1 underflow) or mis-filled.
        InternalSwapPoolHarness harness = new InternalSwapPoolHarness(poolManager, oracle);
        harness.depositFees(poolKey, 0, INVENTORY);
        (uint ethIn, uint tokenOut) = harness.internalSwap(
            poolKey,
            SwapParams({zeroForOne: nativeIsZero, amountSpecified: int(INVENTORY), sqrtPriceLimitX96: limit}),
            nativeIsZero
        );

        // Roles are correct and there is no underflow: native in, memecoin out, bounded by inventory.
        assertGt(ethIn, 0, 'no native taken in');
        assertGt(tokenOut, 0, 'no memecoin given out');
        assertLe(tokenOut, INVENTORY, 'tokenOut exceeded inventory (role swap)');
        assertEq(harness.poolFees(poolKey).amount0, ethIn, 'native leg not credited by ethIn');
        assertEq(harness.poolFees(poolKey).amount1, INVENTORY - tokenOut, 'memecoin leg not debited by tokenOut');

        // The fill was priced from the TWAP, ignoring the user limit entirely (the fix), and NOT
        // from the manipulated spot.
        _assertPricedFromTwapNotSpot(poolId, twap, spotTick, targetExtreme, ethIn, tokenOut);
    }

    /// Mirrors the {InternalSwapPool} exact-output branch and asserts the realized fill was priced
    /// from `_twap`, not from the manipulated `_spotTick`.
    function _assertPricedFromTwapNotSpot(
        PoolId _poolId,
        int24 _twap,
        int24 _spotTick,
        uint160 _targetExtreme,
        uint _ethIn,
        uint _tokenOut
    ) internal view {
        uint128 liquidity = poolManager.getLiquidity(_poolId);
        (, uint ethInTwap, uint tokenOutTwap,) =
            SwapMath.computeSwapStep(TickMath.getSqrtPriceAtTick(_twap), _targetExtreme, liquidity, int(INVENTORY), 0);
        (, uint ethInSpot,,) =
            SwapMath.computeSwapStep(TickMath.getSqrtPriceAtTick(_spotTick), _targetExtreme, liquidity, int(INVENTORY), 0);

        assertEq(_ethIn, ethInTwap, 'eth input not priced from the TWAP');
        assertEq(_tokenOut, tokenOutTwap, 'token output not priced from the TWAP');
        assertTrue(ethInTwap != ethInSpot, 'test setup: TWAP and spot pricing did not diverge');
        assertTrue(_ethIn != ethInSpot, 'fill must not be priced from the manipulated spot');
    }

    function _swap(
        PoolKey memory _poolKey,
        bool _zeroForOne,
        uint _amountIn
    ) internal {
        address input = _zeroForOne ? Currency.unwrap(_poolKey.currency0) : Currency.unwrap(_poolKey.currency1);
        deal(input, address(this), _amountIn);
        IERC20(input).approve(address(poolSwap), _amountIn);

        poolSwap.swap(
            _poolKey,
            SwapParams({
                zeroForOne: _zeroForOne,
                amountSpecified: -int(_amountIn),
                sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }
}
