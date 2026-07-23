// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/Test.sol';

import {TickFinder} from '@flaunch/types/TickFinder.sol';

contract TickFinderTest is Test {
    using TickFinder for int24;

    // Test for valid ticks (already aligned to tick spacing)
    function test_ValidTick() public pure {
        assertEq(int24(0).validTick(true), 0);
        assertEq(int24(60).validTick(true), 60);
        assertEq(int24(-60).validTick(true), -60);
        assertEq(int24(120).validTick(true), 120);
        assertEq(int24(-120).validTick(true), -120);
    }

    // Test for rounding down when the tick is not aligned
    function test_ValidTickRoundDown() public pure {
        // Positive values
        assertEq(int24(59).validTick(true), 0); // Should round down to 0
        assertEq(int24(61).validTick(true), 60); // Should round down to 60
        assertEq(int24(119).validTick(true), 60); // Should round down to 60

        // Negative values
        assertEq(int24(-59).validTick(true), -60); // Should round down to -60
        assertEq(int24(-61).validTick(true), -120); // Should round down to -120
        assertEq(int24(-119).validTick(true), -120); // Should round down to -120
    }

    // Test for rounding up when the tick is not aligned
    function test_ValidTickRoundUp() public pure {
        // Positive values
        assertEq(int24(59).validTick(false), 60); // Should round up to 60
        assertEq(int24(61).validTick(false), 120); // Should round up to 120
        assertEq(int24(119).validTick(false), 120); // Should round up to 120

        // Negative values
        assertEq(int24(-59).validTick(false), 0); // Should round up to 0
        assertEq(int24(-61).validTick(false), -60); // Should round up to -60
        assertEq(int24(-119).validTick(false), -60); // Should round up to -60
    }

    // Test edge cases near zero
    function test_ValidTickEdgeCases() public pure {
        // Zero should remain unchanged
        assertEq(int24(0).validTick(true), 0);
        assertEq(int24(0).validTick(false), 0);

        // Ticks close to zero should round properly
        assertEq(int24(1).validTick(true), 0); // Should round down to 0
        assertEq(int24(1).validTick(false), 60); // Should round up to 60
        assertEq(int24(-1).validTick(true), -60); // Should round down to -60
        assertEq(int24(-1).validTick(false), 0); // Should round up to 0
    }
}
