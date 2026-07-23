// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchTest} from './FlaunchTest.sol';
import {IAnyFlaunch} from '@flaunch-interfaces/IAnyFlaunch.sol';
import {AnyFlaunch} from '@flaunch/AnyFlaunch.sol';

contract AnyFlaunchTest is FlaunchTest {
    constructor() {
        // Deploy our platform
        _deployPlatform();
    }

    function test_setMemecoinTreasuryImplementation_RevertsForNonOwner(
        address _caller
    ) public {
        vm.assume(_caller != flaunch.owner());

        vm.expectRevert(UNAUTHORIZED);
        vm.prank(_caller);
        anyFlaunch.setMemecoinTreasuryImplementation(address(0));
    }

    function test_setMemecoinTreasuryImplementation_SuccessIfOwner(
        address _newImplementation
    ) public {
        vm.expectEmit();
        emit IAnyFlaunch.MemecoinTreasuryImplementationUpdated(_newImplementation);
        anyFlaunch.setMemecoinTreasuryImplementation(_newImplementation);
    }
}
