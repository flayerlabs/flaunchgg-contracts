// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchTest} from './FlaunchTest.sol';
import {IFlaunch} from '@flaunch-interfaces/IFlaunch.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';

contract FlaunchContractTest is FlaunchTest {
    constructor() {
        // Deploy our platform
        _deployPlatform();
    }

    function test_setMemecoinImplementation_RevertsForNonOwner(
        address _caller
    ) public {
        vm.assume(_caller != flaunch.owner());

        vm.expectRevert(UNAUTHORIZED);
        vm.prank(_caller);
        flaunch.setMemecoinImplementation(address(0));
    }

    function test_setMemecoinImplementation_SuccessIfOwner(
        address _newImplementation
    ) public {
        vm.expectEmit();
        emit IFlaunch.MemecoinImplementationUpdated(_newImplementation);
        flaunch.setMemecoinImplementation(_newImplementation);
    }

    function test_setMemecoinTreasuryImplementation_RevertsForNonOwner(
        address _caller
    ) public {
        vm.assume(_caller != flaunch.owner());

        vm.expectRevert(UNAUTHORIZED);
        vm.prank(_caller);
        flaunch.setMemecoinTreasuryImplementation(address(0));
    }

    function test_setMemecoinTreasuryImplementation_SuccessIfOwner(
        address _newImplementation
    ) public {
        vm.expectEmit();
        emit IFlaunch.MemecoinTreasuryImplementationUpdated(_newImplementation);
        flaunch.setMemecoinTreasuryImplementation(_newImplementation);
    }
}
