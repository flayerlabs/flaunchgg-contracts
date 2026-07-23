// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {IOracle} from '@flaunch-interfaces/IOracle.sol';

/**
 * Provides a manipulation-resistant price reference for a pool by storing a ring buffer of
 * tick observations and exposing a time-weighted average tick over a window.
 *
 * Forked and slimmed from Uniswap V3 core's `Oracle` library, then promoted from an inlined
 * library into a standalone contract so its (sizeable) bytecode is deployed once and lives outside
 * the {PositionManager}/{AnyPositionManager} hooks, which sit close to the EIP-170
 * limit. The observation buffers are owned here and only an authorised {InternalSwapPool} (granted
 * the `ORACLE_CONSUMER` role) may record into them.
 *
 * @dev Observations are written at most once per block. Because the buffer is populated from the
 * tick recorded at the start of a block, an attacker cannot influence the historical reference
 * within their own transaction, which is what defeats atomic spot-price manipulation.
 */
contract Oracle is IOracle, AccessControl {
    /// The role permitted to record observations (granted to the {InternalSwapPool})
    bytes32 public constant ORACLE_CONSUMER = keccak256('OracleConsumer');

    /// The averaging window, in seconds, used to price the internal swap (10 minutes)
    uint32 public constant TWAP_WINDOW = 600;

    /// The cap on stored observations per pool. ~10 minutes of coverage at Base's ~2s block time;
    /// the window auto-clamps to available history when the buffer cannot span the full window
    uint16 internal constant MAX_OBSERVATION_CARDINALITY = 300;

    /// The price observation ring buffer for each pool
    mapping(PoolId _poolId => Observation[65535] _observations) internal _observations;

    /// The ring buffer cursor and populated size for each pool
    mapping(PoolId _poolId => ObservationState _state) internal _observationState;

    /**
     * Grants the deployer admin control so it can authorise the {InternalSwapPool} consumer.
     *
     * @param _admin The address granted `DEFAULT_ADMIN_ROLE`
     */
    constructor(
        address _admin
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * Records the current tick into a pool's price oracle, lazily initializing the ring buffer on
     * first use. Writes are deduplicated to at most one per block.
     *
     * @param _poolId The pool whose oracle is being updated
     * @param _tick The current pool tick to record
     */
    function recordObservation(
        PoolId _poolId,
        int24 _tick
    ) external onlyRole(ORACLE_CONSUMER) {
        ObservationState memory state = _observationState[_poolId];

        // On first use, seed the genesis observation and store the initial cursor state
        if (state.cardinality == 0) {
            _observationState[_poolId] =
                ObservationState({index: 0, cardinality: initialize(_observations[_poolId], uint32(block.timestamp))});
            return;
        }

        // Append the observation, allowing the buffer to grow toward its cardinality cap
        (uint16 indexUpdated, uint16 cardinalityUpdated) =
            write(_observations[_poolId], state.index, uint32(block.timestamp), _tick, state.cardinality, MAX_OBSERVATION_CARDINALITY);

        // Persist the cursor only when the write actually advanced it (skipped within a block)
        if (indexUpdated != state.index || cardinalityUpdated != state.cardinality) {
            _observationState[_poolId] = ObservationState({index: indexUpdated, cardinality: cardinalityUpdated});
        }
    }

    /**
     * Returns the time-weighted average tick used to price the internal swap, falling back to the
     * current tick before the oracle has any history.
     *
     * @param _poolId The pool to price
     * @param _currentTick The current pool tick, used as the warm-up fallback
     *
     * @return twapTick_ The tick to price the internal fill against
     */
    function twapTick(
        PoolId _poolId,
        int24 _currentTick
    ) external view returns (int24 twapTick_) {
        ObservationState memory state = _observationState[_poolId];

        // Until the oracle has been initialized there is no history, so use the current tick
        if (state.cardinality == 0) {
            return _currentTick;
        }

        twapTick_ = consult(_observations[_poolId], uint32(block.timestamp), _currentTick, state.index, state.cardinality, TWAP_WINDOW);
    }

    /**
     * Returns the {ObservationState} cursor for a pool.
     *
     * @param _poolId The pool to read
     */
    function observationState(
        PoolId _poolId
    ) external view returns (ObservationState memory) {
        return _observationState[_poolId];
    }

    /**
     * Transforms a previous observation into a new one given the elapsed time and current tick.
     *
     * @dev `blockTimestamp` must be chronologically equal to or after `last.blockTimestamp`; the
     * subtraction is `unchecked` so it is safe across a single 32-bit timestamp overflow.
     */
    function transform(
        Observation memory _last,
        uint32 _blockTimestamp,
        int24 _tick
    ) private pure returns (Observation memory) {
        unchecked {
            // Seconds elapsed since the previous observation (wraps safely across uint32 overflow)
            uint32 delta = _blockTimestamp - _last.blockTimestamp;

            // Accumulate `tick * delta` onto the running cumulative
            return Observation({
                blockTimestamp: _blockTimestamp,
                tickCumulative: _last.tickCumulative + int56(_tick) * int56(uint56(delta)),
                initialized: true
            });
        }
    }

    /**
     * Initializes the oracle array by writing the genesis observation.
     */
    function initialize(
        Observation[65535] storage _self,
        uint32 _time
    ) private returns (uint16 cardinality_) {
        // Seed slot 0 with a zero cumulative anchored at the current time
        _self[0] = Observation({blockTimestamp: _time, tickCumulative: 0, initialized: true});
        cardinality_ = 1;
    }

    /**
     * Writes an observation to the array, growing the populated cardinality up to a maximum as the
     * buffer fills.
     */
    function write(
        Observation[65535] storage _self,
        uint16 _index,
        uint32 _blockTimestamp,
        int24 _tick,
        uint16 _cardinality,
        uint16 _maxCardinality
    ) private returns (uint16 indexUpdated_, uint16 cardinalityUpdated_) {
        Observation memory last = _self[_index];

        // Only one observation is recorded per block; bail if we already wrote this block
        if (last.blockTimestamp == _blockTimestamp) {
            return (_index, _cardinality);
        }

        // Grow the buffer by one while we are at its populated edge and below the cap, otherwise
        // keep the current cardinality and wrap around
        if (_cardinality < _maxCardinality && _index == _cardinality - 1) {
            cardinalityUpdated_ = _cardinality + 1;
        } else {
            cardinalityUpdated_ = _cardinality;
        }

        // Advance the write cursor and store the transformed observation
        indexUpdated_ = (_index + 1) % cardinalityUpdated_;
        _self[indexUpdated_] = transform(last, _blockTimestamp, _tick);
    }

    /**
     * 32-bit timestamp comparator that is safe across a single overflow.
     */
    function lte(
        uint32 _time,
        uint32 _a,
        uint32 _b
    ) private pure returns (bool) {
        // If neither value has wrapped past `_time`, a plain comparison is correct
        if (_a <= _time && _b <= _time) {
            return _a <= _b;
        }

        // Otherwise rebase any wrapped values into a continuous range before comparing
        uint aAdjusted = _a > _time ? _a : _a + 2 ** 32;
        uint bAdjusted = _b > _time ? _b : _b + 2 ** 32;
        return aAdjusted <= bAdjusted;
    }

    /**
     * Binary searches the array for the observations immediately before and after a target time.
     */
    function binarySearch(
        Observation[65535] storage _self,
        uint32 _time,
        uint32 _target,
        uint16 _index,
        uint16 _cardinality
    ) private view returns (Observation memory beforeOrAt_, Observation memory atOrAfter_) {
        unchecked {
            uint l = (_index + 1) % _cardinality; // oldest observation
            uint r = l + _cardinality - 1; // newest observation
            uint i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt_ = _self[i % _cardinality];

                // Skip uninitialized slots, searching more recently
                if (!beforeOrAt_.initialized) {
                    l = i + 1;
                    continue;
                }

                atOrAfter_ = _self[(i + 1) % _cardinality];

                bool targetAtOrAfter = lte(_time, beforeOrAt_.blockTimestamp, _target);

                // We have bracketed the target between two adjacent observations
                if (targetAtOrAfter && lte(_time, _target, atOrAfter_.blockTimestamp)) {
                    break;
                }

                if (!targetAtOrAfter) {
                    r = i - 1;
                } else {
                    l = i + 1;
                }
            }
        }
    }

    /**
     * Fetches the observations surrounding a target time, simulating the newest observation
     * forward to `_target` when the target is newer than anything stored.
     */
    function getSurroundingObservations(
        Observation[65535] storage _self,
        uint32 _time,
        uint32 _target,
        int24 _tick,
        uint16 _index,
        uint16 _cardinality
    ) private view returns (Observation memory beforeOrAt_, Observation memory atOrAfter_) {
        // Optimistically start at the newest observation
        beforeOrAt_ = _self[_index];

        // If the target is at or after the newest observation we can answer without searching
        if (lte(_time, beforeOrAt_.blockTimestamp, _target)) {
            if (beforeOrAt_.blockTimestamp == _target) {
                // Target is the newest observation; the right side is unused
                return (beforeOrAt_, atOrAfter_);
            }
            // Target is in the future of the newest observation; simulate forward to it
            return (beforeOrAt_, transform(beforeOrAt_, _target, _tick));
        }

        // Otherwise fall back to the oldest observation
        beforeOrAt_ = _self[(_index + 1) % _cardinality];
        if (!beforeOrAt_.initialized) {
            beforeOrAt_ = _self[0];
        }

        // The target must not predate the oldest stored observation
        require(lte(_time, beforeOrAt_.blockTimestamp, _target), 'OLD');

        // Binary search the interior of the array
        return binarySearch(_self, _time, _target, _index, _cardinality);
    }

    /**
     * Returns the `tickCumulative` as of `_secondsAgo`, interpolating between observations when the
     * target falls between two of them.
     */
    function observeSingle(
        Observation[65535] storage _self,
        uint32 _time,
        uint32 _secondsAgo,
        int24 _tick,
        uint16 _index,
        uint16 _cardinality
    ) private view returns (int56 tickCumulative_) {
        unchecked {
            // A zero look-back returns the current cumulative, simulated to now if needed
            if (_secondsAgo == 0) {
                Observation memory last = _self[_index];
                if (last.blockTimestamp != _time) {
                    last = transform(last, _time, _tick);
                }
                return last.tickCumulative;
            }

            uint32 target = _time - _secondsAgo;

            (Observation memory beforeOrAt, Observation memory atOrAfter) =
                getSurroundingObservations(_self, _time, target, _tick, _index, _cardinality);

            if (target == beforeOrAt.blockTimestamp) {
                // Landed exactly on the left boundary
                return beforeOrAt.tickCumulative;
            } else if (target == atOrAfter.blockTimestamp) {
                // Landed exactly on the right boundary
                return atOrAfter.tickCumulative;
            }

            // Interpolate linearly between the two surrounding observations
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            return beforeOrAt.tickCumulative
                + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(observationTimeDelta)))
                * int56(uint56(targetDelta));
        }
    }

    /**
     * Returns the time-weighted average tick over the requested window, automatically clamping the
     * window to the available history so that freshly launched pools degrade gracefully.
     */
    function consult(
        Observation[65535] storage _self,
        uint32 _time,
        int24 _currentTick,
        uint16 _index,
        uint16 _cardinality,
        uint32 _window
    ) private view returns (int24 arithmeticMeanTick_) {
        // Find the oldest stored observation to bound how far back we can actually average
        Observation memory oldest = _self[(_index + 1) % _cardinality];
        if (!oldest.initialized) {
            oldest = _self[0];
        }

        // Clamp the requested window to the age of the oldest observation
        uint32 maxWindow;
        unchecked {
            maxWindow = _time - oldest.blockTimestamp;
        }
        uint32 effectiveWindow = _window > maxWindow ? maxWindow : _window;

        // With no prior-block history the current tick is the only safe reference
        if (effectiveWindow == 0) {
            return _currentTick;
        }

        // Read the cumulative at the start and end of the effective window
        int56 startCumulative = observeSingle(_self, _time, effectiveWindow, _currentTick, _index, _cardinality);
        int56 endCumulative = observeSingle(_self, _time, 0, _currentTick, _index, _cardinality);

        // Average the tick over the window, rounding toward negative infinity
        int56 tickCumulativeDelta = endCumulative - startCumulative;
        int56 windowInt = int56(uint56(effectiveWindow));
        arithmeticMeanTick_ = int24(tickCumulativeDelta / windowInt);
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % windowInt != 0)) {
            arithmeticMeanTick_--;
        }
    }
}
