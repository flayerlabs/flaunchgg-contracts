// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * A helper library that finds the next valid tick for the specified tick spacing, starting
 * from a single tick. This will allow us to round up or down to find it and also supports
 * negative rounding.
 *
 * This is beneficial as it allows us to create positions directly next to the current tick.
 *
 * @dev This is used by `using TickFinder for int24;`
 */
library TickFinder {
    /// The valid tick spacing value for the pool
    int24 internal constant TICK_SPACING = 60;

    /// Set our min/max tick range that is valid for the tick spacing
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;

    /**
     * Helper function to find the nearest valid tick, rounding up or down.
     *
     * @param _tick The tick that we want to find a valid value for
     * @param _roundDown If we want to round down (true) or up (false)
     *
     * return tick_ The valid tick
     */
    function validTick(
        int24 _tick,
        bool _roundDown
    ) internal pure returns (int24 tick_) {
        // If we have a malformed tick, then we need to bring it back within range
        if (_tick < MIN_TICK) {
            _tick = MIN_TICK;
        } else if (_tick > MAX_TICK) {
            _tick = MAX_TICK;
        }

        // If the tick is already valid, exit early
        if (_tick % TICK_SPACING == 0) {
            return _tick;
        }

        tick_ = _tick / TICK_SPACING * TICK_SPACING;
        if (_tick < 0) {
            tick_ -= TICK_SPACING;
        }

        // If we are rounding up, then we can just add a `TICK_SPACING` to the lower tick
        if (!_roundDown) {
            return tick_ + TICK_SPACING;
        }
    }
}
