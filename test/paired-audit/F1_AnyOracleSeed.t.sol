// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {ERC20Mock} from 'test/tokens/ERC20Mock.sol';

import {InternalSwapPoolHarness} from '../hooks/InternalSwapPool.t.sol';
import {FlaunchTest} from '../FlaunchTest.sol';
import {IAnyPositionManager} from '@flaunch-interfaces/IAnyPositionManager.sol';
import {IInternalSwapPool} from '@flaunch-interfaces/IInternalSwapPool.sol';

/**
 * Regression coverage for audit finding F-1.
 *
 * `AnyPositionManager` shares the {InternalSwapPool}, whose fill is priced at
 * `oracle.twapTick(...)`. Before the fix the Any manager held no {Oracle} reference and never
 * recorded an observation, so every Any pool had `cardinality == 0` for life and `twapTick`
 * degraded to the (manipulable) live spot tick.
 *
 * The fix seeds the oracle with a genesis observation at flaunch time and records the pre-swap
 * tick on every swap, mirroring {PositionManager}. It also degrades the {InternalSwapPool} fill
 * to a no-fill when the oracle has never been seeded (defense-in-depth).
 *
 * These tests assert:
 *   1. the oracle is seeded (`cardinality != 0`) at flaunch and keeps recording on swaps, and
 *   2. an actual {InternalSwapPool} fill on an Any pool is priced from the recorded TWAP, not
 *      from an atomically-manipulated spot price.
 */
contract F1AnyOracleSeedTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    address internal memecoin;

    function setUp() public {
        _deployPlatform();
    }

    /* -----------------------------------------------------------------------
     * 1. Oracle is seeded at flaunch and keeps recording on swaps.
     * --------------------------------------------------------------------- */

    function test_F1_OracleSeededOnAnyFlaunch() public {
        PoolKey memory poolKey = _flaunchAny();
        PoolId poolId = poolKey.toId();

        // Genesis observation recorded at flaunch. Pre-fix this was 0 for the life of the pool.
        assertEq(oracle.observationState(poolId).cardinality, 1, 'oracle not seeded at flaunch');
    }

    function test_F1_OracleRecordsObservationOnAnySwap() public {
        PoolKey memory poolKey = _flaunchAny();
        PoolId poolId = poolKey.toId();
        _addAnyLiquidity(poolKey);

        // Advance a block so the per-swap observation actually appends (writes are deduped to at
        // most one per block timestamp).
        vm.warp(block.timestamp + 60);
        _swapAny(poolKey, _nativeIsZero(poolKey), 1 ether);

        // The buffer grew: an observation was recorded on the swap in addition to the genesis one.
        assertGe(oracle.observationState(poolId).cardinality, 2, 'oracle did not record on swap');
    }

    /* -----------------------------------------------------------------------
     * 2. The InternalSwapPool fill is priced from the recorded TWAP, not spot.
     *
     * Build a seeded oracle history, then atomically shove spot far from the recorded tick and
     * drive an exact-output fill through a harness that shares the same oracle. The realized fill
     * must match the TWAP-priced computation and NOT the spot-priced one, so the extractable value
     * cannot be moved by manipulating spot inside the swapper's own transaction.
     * --------------------------------------------------------------------- */

    /// @dev The exact-output inventory used by the fill test; also the amount requested out.
    uint internal constant INVENTORY = 1 ether;

    function test_F1_IspFillPricedFromSeededTwapNotSpot() public {
        PoolKey memory poolKey = _flaunchAny();
        PoolId poolId = poolKey.toId();
        _addAnyLiquidity(poolKey);

        bool nativeIsZero = _nativeIsZero(poolKey);

        // The tick recorded into the oracle at flaunch (nothing has moved spot yet).
        (, int24 genesisTick,,) = poolManager.getSlot0(poolId);

        // Let a full TWAP window elapse so `consult()` has real history to average over, then
        // atomically shove spot away from the recorded tick by selling memecoin into the pool. The
        // swap's `beforeSwap` records an observation at the (still-genesis) pre-swap tick and only
        // then does spot move, so the recorded history stays anchored to the genesis tick.
        vm.warp(block.timestamp + 600);
        _swapAny(poolKey, !nativeIsZero, 500 ether);

        int24 spotTick;
        (, spotTick,,) = poolManager.getSlot0(poolId);
        int24 twap = oracle.twapTick(poolId, spotTick);

        // The TWAP the fill prices against resisted the atomic manipulation.
        assertTrue(spotTick != genesisTick, 'spot did not move');
        assertEq(twap, genesisTick, 'twap must track the recorded observation, not spot');

        // Drive an exact-output fill through a harness that shares the live oracle + pool state.
        InternalSwapPoolHarness harness = new InternalSwapPoolHarness(poolManager, oracle);
        harness.depositFees(poolKey, 0, INVENTORY);

        uint160 targetExtreme = nativeIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint ethIn, uint tokenOut) = harness.internalSwap(
            poolKey,
            SwapParams({zeroForOne: nativeIsZero, amountSpecified: int(INVENTORY), sqrtPriceLimitX96: targetExtreme}),
            nativeIsZero
        );

        // The realized fill must equal the TWAP-priced computation and differ from what pricing
        // off the manipulated spot would have produced.
        (uint ethInTwap, uint tokenOutTwap) = _pricedFill(poolId, twap, targetExtreme);
        (uint ethInSpot,) = _pricedFill(poolId, spotTick, targetExtreme);

        assertGt(ethIn, 0, 'fill produced no eth input');
        assertGt(tokenOut, 0, 'fill produced no token output');
        assertEq(ethIn, ethInTwap, 'eth input not priced from the recorded TWAP');
        assertEq(tokenOut, tokenOutTwap, 'token output not priced from the recorded TWAP');
        assertTrue(ethInTwap != ethInSpot, 'test setup: TWAP and spot pricing did not diverge');
        assertTrue(ethIn != ethInSpot, 'fill must not be priced from the manipulated spot');

        // The inventory accounting is consistent (no underflow / role-swap): memecoin out, eth in.
        IInternalSwapPool.ClaimableFees memory fees = harness.poolFees(poolKey);
        assertEq(fees.amount0, ethIn, 'native leg not credited by ethIn');
        assertEq(fees.amount1, INVENTORY - tokenOut, 'memecoin leg not debited by tokenOut');
    }

    /// Mirrors the {InternalSwapPool} exact-output branch: prices `INVENTORY` out at `_tick`.
    function _pricedFill(
        PoolId _poolId,
        int24 _tick,
        uint160 _targetExtreme
    ) internal view returns (uint ethIn_, uint tokenOut_) {
        (, ethIn_, tokenOut_,) = SwapMath.computeSwapStep(
            TickMath.getSqrtPriceAtTick(_tick), _targetExtreme, poolManager.getLiquidity(_poolId), int(INVENTORY), 0
        );
    }

    /* -----------------------------------------------------------------------
     * Helpers
     * --------------------------------------------------------------------- */

    function _flaunchAny() internal returns (PoolKey memory poolKey_) {
        memecoin = address(new ERC20Mock(address(this)));
        ERC20Mock(memecoin).mint(address(this), 1_000_000 ether);

        anyPositionManager.approveCreator(address(this), true);
        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        poolKey_ = anyPositionManager.poolKey(memecoin);
    }

    function _addAnyLiquidity(
        PoolKey memory _poolKey
    ) internal {
        deal(address(anyPositionManager.nativeToken()), address(this), 10e27);
        IERC20(anyPositionManager.nativeToken()).approve(address(poolModifyPosition), type(uint).max);

        deal(memecoin, address(this), 10e27);
        IERC20(memecoin).approve(address(poolModifyPosition), type(uint).max);

        poolModifyPosition.modifyLiquidity(
            _poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(_poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(_poolKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: ''
            }),
            ''
        );
    }

    function _swapAny(
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

    function _nativeIsZero(
        PoolKey memory _poolKey
    ) internal view returns (bool) {
        return Currency.unwrap(_poolKey.currency0) == anyPositionManager.nativeToken();
    }
}
