// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {IInternalSwapPool} from '@flaunch-interfaces/IInternalSwapPool.sol';
import {IOracle} from '@flaunch-interfaces/IOracle.sol';

/**
 * Frontruns Uniswap to sell undesired token amounts from protocol fees into desired tokens ahead
 * of fee distribution, acting as a partial orderbook that removes impact against the pool.
 *
 * The authorised hooks hold the `POSITION_MANAGER` role; they call {internalSwap} / {depositFees} /
 * {recordObservation} and perform the actual {PoolManager} `take`/`settle` themselves, since those
 * must be attributed to the hook (the swap delta owner).
 *
 * @dev The internal fill prices the protocol's fee inventory against a manipulation-resistant TWAP
 * (see {Oracle}) rather than the live spot price, so the conversion cannot be drained by atomic
 * spot-price manipulation within the swapper's own transaction.
 */
contract InternalSwapPool is IInternalSwapPool, AccessControl {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// The Uniswap V4 {PoolManager} the hooks operate against
    IPoolManager public immutable poolManager;

    /// The price {Oracle} used to price internal fills
    IOracle public immutable oracle;

    /// Maps the amount of claimable tokens that are available to be `distributed` for a `PoolId`
    mapping(PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    /**
     * Stores the {PoolManager} and {Oracle} references and grants the deployer admin control so it
     * can authorise the consuming hooks.
     *
     * @param _poolManager The Uniswap V4 {PoolManager}
     * @param _oracle The price {Oracle} contract
     * @param _admin The address granted `DEFAULT_ADMIN_ROLE`
     */
    constructor(
        IPoolManager _poolManager,
        IOracle _oracle,
        address _admin
    ) {
        poolManager = _poolManager;
        oracle = _oracle;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * Provides the {ClaimableFees} for a pool key.
     *
     * @param _poolKey The PoolKey to check
     *
     * @return The {ClaimableFees} for the PoolKey
     */
    function poolFees(
        PoolKey memory _poolKey
    ) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    /**
     * Allows an authorised hook to allocate fees against a pool.
     *
     * @dev `_amount0` always refers to the native token, `_amount1` the underlying memecoin.
     *
     * @param _poolKey The PoolKey to deposit against
     * @param _amount0 The amount of eth equivalent to deposit
     * @param _amount1 The amount of underlying token to deposit
     */
    function depositFees(
        PoolKey memory _poolKey,
        uint _amount0,
        uint _amount1
    ) external onlyRole(ProtocolRoles.POSITION_MANAGER) {
        PoolId poolId = _poolKey.toId();

        _poolFees[poolId].amount0 += _amount0;
        _poolFees[poolId].amount1 += _amount1;

        emit PoolFeesReceived(poolId, _amount0, _amount1);
    }

    /**
     * Clears and returns the native-token fees accumulated for a pool, ready for the calling hook
     * to distribute.
     *
     * @param _poolId The pool to consume native fees for
     *
     * @return amount0_ The native-token fee amount that was cleared
     */
    function resetNativeFees(
        PoolId _poolId
    ) external onlyRole(ProtocolRoles.POSITION_MANAGER) returns (uint amount0_) {
        amount0_ = _poolFees[_poolId].amount0;
        _poolFees[_poolId].amount0 = 0;
    }

    /**
     * Computes the internal fill against the protocol's fee inventory and updates the stored fees.
     *
     * @dev This does NOT touch the {PoolManager}: the caller (an authorised hook holding the swap
     * delta) performs the corresponding `take` (native, `ethIn_`) and `settle` (memecoin,
     * `tokenOut_`). The fill is priced against the manipulation-resistant TWAP, never spot.
     *
     * @param _key The PoolKey that is being swapped against
     * @param _params The swap parameters
     * @param _nativeIsZero If our native token is `currency0`
     *
     * @return ethIn_ The ETH taken for the swap
     * @return tokenOut_ The tokens given for the swap
     */
    function internalSwap(
        PoolKey calldata _key,
        SwapParams memory _params,
        bool _nativeIsZero
    ) external onlyRole(ProtocolRoles.POSITION_MANAGER) returns (uint ethIn_, uint tokenOut_) {
        PoolId poolId = _key.toId();

        // Read the current pool tick up front. The internal fill settles against the hook's own
        // balances and never moves the pool, so this is the genuine pre-swap tick for the block.
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Load our PoolFees as storage as we will manipulate them later if we trigger
        ClaimableFees storage pendingPoolFees = _poolFees[poolId];
        if (pendingPoolFees.amount1 == 0) {
            return (ethIn_, tokenOut_);
        }

        // We only want to process our internal swap if we are buying non-ETH tokens with ETH. This
        // will allow us to correctly calculate the amount of token to replace.
        if (_nativeIsZero != _params.zeroForOne) {
            return (ethIn_, tokenOut_);
        }

        // Defense-in-depth: if the oracle has never recorded an observation for this pool then
        // `twapTick` falls back to the caller-supplied spot tick, which is manipulable within the
        // swapper's own transaction. Rather than pricing the fill at spot, degrade to a no-fill so
        // any consumer that has not seeded the oracle simply lets the outer pool swap absorb the
        // full user input. Correctly-seeded pools always have a non-zero cardinality and are
        // unaffected.
        if (oracle.observationState(poolId).cardinality == 0) {
            return (0, 0);
        }

        // Price the protocol's fee inventory against the manipulation-resistant TWAP rather than
        // the live spot price (see security finding H-4). This prevents an attacker from atomically
        // moving spot to buy the inventory at an artificial price within their own swap.
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(oracle.twapTick(poolId, currentTick));

        // Since we have a positive amountSpecified, we can determine the maximum
        // amount that we can transact from our pool fees.
        if (_params.amountSpecified >= 0) {
            // Take the max value of either the pool fees or the amount specified to swap for
            uint amountSpecified =
                (uint(_params.amountSpecified) > pendingPoolFees.amount1) ? pendingPoolFees.amount1 : uint(_params.amountSpecified);

            // Capture the amount of desired token required at the current pool state to
            // purchase the amount of token specified, capped by the pool fees available.
            //
            // `SwapMath.computeSwapStep` infers the swap direction from
            // `sqrtPriceCurrentX96 >= sqrtPriceTargetX96`. Because `sqrtPriceCurrentX96` is the
            // TWAP (not spot), passing the user's raw `sqrtPriceLimitX96` as the target would let a
            // TWAP that has diverged past that limit flip the inferred direction, swapping the
            // native/memecoin roles of `(ethIn_, tokenOut_)` and underflowing `amount1` below. The
            // pool's direction is already asserted above (`_nativeIsZero == _params.zeroForOne`),
            // so pin the target to the matching price extreme, mirroring the exact-input branch.
            (, ethIn_, tokenOut_,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: _nativeIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: int(amountSpecified),
                feePips: 0
            });
        }
        // As we have a negative amountSpecified, this means that we are spending any amount
        // of token to get a specific amount of undesired token.
        else {
            // To calculate the amount of tokens that we can receive, we first pass in the amount
            // of ETH that we are requesting to spend. We need to invert the `sqrtPriceTargetX96`
            // as our swap step computation is essentially calculating the opposite direction.
            (, tokenOut_, ethIn_,) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: _params.zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
                liquidity: poolManager.getLiquidity(poolId),
                amountRemaining: int(-_params.amountSpecified),
                feePips: 0
            });

            // If we cannot fulfill the full amount of the internal orderbook, then we want to
            // calculate the percentage of which we can utilize. We use `FullMath.mulDiv` to
            // perform the multiplication with overflow protection before the division.
            if (tokenOut_ > pendingPoolFees.amount1) {
                ethIn_ = FullMath.mulDiv(pendingPoolFees.amount1, ethIn_, tokenOut_);
                tokenOut_ = pendingPoolFees.amount1;
            }
        }

        // If either side rounded to zero (typically when the integer-division rescale clips
        // `ethIn_` or when the available inventory is below `SwapMath` precision) we cannot
        // perform a balanced settlement, so skip the internal fill entirely and let the
        // outer pool swap absorb the full user input.
        if (ethIn_ == 0 || tokenOut_ == 0) {
            return (0, 0);
        }

        // Reduce the amount of fees that have been extracted from the pool and converted
        // into ETH fees.
        pendingPoolFees.amount0 += ethIn_;
        pendingPoolFees.amount1 -= tokenOut_;

        // Capture the swap cost that we captured from our drip. The caller performs the matching
        // `take`/`settle` against the {PoolManager}.
        emit PoolFeesSwapped(poolId, _params.zeroForOne, ethIn_, tokenOut_);
    }
}
