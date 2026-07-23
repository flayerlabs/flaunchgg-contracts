// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

interface IOracle {
    /**
     * A single stored observation. Packs into one storage slot (32 + 56 + 8 bits).
     *
     * @member blockTimestamp The block timestamp of the observation
     * @member tickCumulative The tick accumulator, i.e. tick * seconds elapsed since the oracle
     * was first initialized
     * @member initialized Whether the observation slot has been populated
     */
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    /**
     * Tracks the position and size of a pool's observation ring buffer.
     *
     * @member index The index of the most recently written observation
     * @member cardinality The number of populated observation slots (0 until initialized)
     */
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
    }

    function recordObservation(
        PoolId _poolId,
        int24 _tick
    ) external;

    function twapTick(
        PoolId _poolId,
        int24 _currentTick
    ) external view returns (int24 twapTick_);

    function observationState(
        PoolId _poolId
    ) external view returns (ObservationState memory);
}
