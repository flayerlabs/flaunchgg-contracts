// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract FlaunchFeeExemptionTest is FlaunchTest {
    address owner = address(0x123);
    address nonOwner = address(0x456);

    function setUp() public {
        _deployPlatform();
    }

    function test_CanSetFeeExemption(
        address _beneficiary,
        bool _excluded
    ) public {
        vm.expectEmit();
        emit FlaunchFeeExemption.FeeExemptionUpdated(_beneficiary, _excluded);

        flaunchFeeExemption.setFeeExemption(_beneficiary, _excluded);

        assertEq(flaunchFeeExemption.feeExcluded(_beneficiary), _excluded);
    }

    function test_CannotSetFeeExemption_IfNotOwner(
        address _caller
    ) public {
        vm.assume(_caller != address(this));

        vm.startPrank(_caller);

        vm.expectRevert(UNAUTHORIZED);
        flaunchFeeExemption.setFeeExemption(_caller, true);

        vm.stopPrank();
    }
}
