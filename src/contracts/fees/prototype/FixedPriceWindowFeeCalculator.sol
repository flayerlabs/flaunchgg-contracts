// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

/**
 * PROTOTYPE — Option A from FIXED_PRICE_INVESTIGATION.md. NOT audited, NOT tested, NOT for
 * production. It exists to make the "no-PositionManager-change, no-redeploy" shape concrete.
 *
 * Goal: offer a memecoin at a fixed price (the launch tick) for a window bounded by EITHER an
 * amount of memecoin sold OR a duration measured from launch, without modifying or redeploying the
 * {PositionManager}.
 *
 * How it stays non-invasive:
 *  - It is a drop-in {IFeeCalculator} that the protocol owner swaps in via `FeeDistributor.
 *    setFeeCalculator(...)` — no PM redeploy.
 *  - It WRAPS an existing calculator (`inner`, e.g. the live {TrustedSignerFeeCalculator}) and
 *    delegates every call to it, so pools that do not opt in behave exactly as they do today.
 *  - It stamps its own `launchedAt` in {setFlaunchParams} (called at flaunch), so it needs no
 *    launch timestamp from the PM (the PM deletes `flaunchesAt` when trading opens).
 *
 * How the fixed price is enforced (see the honest limitations in the investigation doc):
 *  - A single-tick memecoin position must be seeded at the launch tick by a helper in the flaunch
 *    tx (e.g. via {FlaunchZap}); `beforeAddLiquidity` is not hooked, so liquidity can be added
 *    freely. That position is the fixed-price supply buyers fill against.
 *  - Enforcement happens in {trackSwap} (state-mutating, runs AFTER the swap with post-swap state):
 *    while in-window, a buy that moved the pool tick PAST the fixed tick reverts the whole swap.
 *    Buys that fill entirely at the fixed tick (against the seeded position) succeed. This is a
 *    revert, not a partial fill — frontends must size buys to the remaining fixed-price supply.
 */
contract FixedPriceWindowFeeCalculator is IFeeCalculator, Ownable {

    using StateLibrary for IPoolManager;

    error NotConfigured();
    error BuyPushedPriceAboveFixedDuringWindow(int24 currentTick, int24 fixedTick);

    enum Mode { Disabled, Amount, Time }

    struct Window {
        Mode mode;             // Disabled = behave exactly like `inner`
        int24 fixedTick;       // price ceiling; 0-sentinel means "read initialPoolTick at launch"
        uint windowAmount;     // Amount mode: max memecoin sellable at the fixed price
        uint windowDuration;   // Time mode: seconds from `launchedAt`
        uint launchedAt;       // stamped in setFlaunchParams
        uint amountSold;       // accumulated in trackSwap (memecoin bought during the window)
    }

    /// The wrapped calculator that retains all existing behaviour (trusted signer, caps, fees)
    IFeeCalculator public immutable inner;

    /// The Uniswap V4 pool manager, used to read the live tick post-swap
    IPoolManager public immutable poolManager;

    /// The protocol native token (flETH), used to identify the memecoin side of a pool
    address public immutable nativeToken;

    /// Per-pool fixed-price window configuration
    mapping(PoolId _poolId => Window _window) public windows;

    constructor(IFeeCalculator _inner, IPoolManager _poolManager, address _nativeToken) {
        inner = _inner;
        poolManager = _poolManager;
        nativeToken = _nativeToken;
        _initializeOwner(msg.sender);
    }

    /**
     * Opt a pool into a fixed-price window. In production this would be folded into
     * `feeCalculatorParams` and driven from the flaunch call; kept as a separate call here to avoid
     * entangling the prototype with the inner calculator's params ABI. Intended to be called in the
     * same flaunch tx (e.g. by the zap) by the pool creator / protocol.
     *
     * @param _poolId The pool to configure
     * @param _mode Amount- or Time-bounded window
     * @param _fixedTick The fixed price as a tick (0 to bind to the pool's `initialPoolTick`)
     * @param _windowAmount Amount mode: memecoin units sellable at the fixed price
     * @param _windowDuration Time mode: seconds from launch
     */
    function configureWindow(
        PoolId _poolId,
        Mode _mode,
        int24 _fixedTick,
        uint _windowAmount,
        uint _windowDuration
    ) external onlyOwner {
        Window storage w = windows[_poolId];
        w.mode = _mode;
        w.fixedTick = _fixedTick;
        w.windowAmount = _windowAmount;
        w.windowDuration = _windowDuration;
    }

    /* ----------------------------- IFeeCalculator ----------------------------- */

    /// Fees are unchanged: pure delegation. The fixed-price guard lives in {trackSwap}, which has
    /// post-swap state; a view fee function cannot tell a fill-at-tick from a push-past-tick.
    function determineSwapFee(
        PoolKey memory _poolKey,
        SwapParams memory _params,
        uint24 _baseFee
    ) external view returns (uint24 swapFee_) {
        return inner.determineSwapFee(_poolKey, _params, _baseFee);
    }

    function trackSwap(
        address _sender,
        PoolKey calldata _poolKey,
        SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) external {
        // Preserve all existing post-swap behaviour first
        inner.trackSwap(_sender, _poolKey, _params, _delta, _hookData);

        PoolId poolId = _poolKey.toId();
        Window storage w = windows[poolId];
        if (w.mode == Mode.Disabled) {
            return;
        }

        bool nativeIsZero = Currency.unwrap(_poolKey.currency0) == nativeToken;

        // Memecoin bought this swap (positive when the user received memecoin, i.e. a buy)
        int memeDelta = nativeIsZero ? _delta.amount1() : _delta.amount0();
        bool isBuy = memeDelta > 0;
        if (!isBuy) {
            // Sells are left to the inner calculator in this prototype. Production could also gate
            // sells during the window (cf. the old FairLaunch `CannotSellTokenDuringFairLaunch`).
            return;
        }

        // Is the window still open?
        bool inWindow = w.mode == Mode.Amount
            ? w.amountSold < w.windowAmount
            : block.timestamp < w.launchedAt + w.windowDuration;

        if (inWindow) {
            int24 fixedTick = w.fixedTick;
            if (fixedTick == 0) {
                fixedTick = IPositionManager(address(_poolKey.hooks)).initialPoolTick(poolId);
            }

            (, int24 currentTick,,) = poolManager.getSlot0(poolId);

            // Memecoin appreciates as the tick moves away from the launch tick in the direction the
            // wide memecoin band extends: down when native is token0, up when native is token1.
            bool pushedPastFixed = nativeIsZero ? currentTick < fixedTick : currentTick > fixedTick;
            if (pushedPastFixed) {
                revert BuyPushedPriceAboveFixedDuringWindow(currentTick, fixedTick);
            }

            // Count the fixed-price memecoin sold; closes the Amount-mode window when it fills.
            w.amountSold += uint(memeDelta);
        }
    }

    function setFlaunchParams(
        PoolId _poolId,
        bytes calldata _params
    ) external {
        // Delegate so the inner calculator records its own per-pool config unchanged
        inner.setFlaunchParams(_poolId, _params);

        // Stamp launch time for Time-mode windows. Safe even if the pool never opts in.
        windows[_poolId].launchedAt = block.timestamp;
    }
}
