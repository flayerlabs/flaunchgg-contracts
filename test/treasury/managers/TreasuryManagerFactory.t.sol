// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';

import {TreasuryManagerMock} from 'test/mocks/TreasuryManagerMock.sol';
import {FlaunchTest} from 'test/FlaunchTest.sol';


contract TreasuryManagerFactoryTest is FlaunchTest {

    /// Define some EOA addresses to test with
    address nonOwner = address(0x456);

    address managerImplementation;
    bytes data;

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        // Deploy a mocked manager implementation
        managerImplementation = address(new TreasuryManagerMock(address(treasuryManagerFactory)));

        // Create some test data that we can pass
        data = abi.encode('Test initialization');
    }

    function test_approveManager() public {
        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerImplementationApproved(managerImplementation);

        treasuryManagerFactory.approveManager(managerImplementation);
        assertTrue(treasuryManagerFactory.approvedManagerImplementation(managerImplementation));
    }

    function test_approveManager_notOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert(UNAUTHORIZED);
        treasuryManagerFactory.approveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_unapproveManager() public {
        treasuryManagerFactory.approveManager(managerImplementation);

        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerImplementationUnapproved(managerImplementation);

        treasuryManagerFactory.unapproveManager(managerImplementation);
        vm.stopPrank();

        assertFalse(treasuryManagerFactory.approvedManagerImplementation(managerImplementation));
    }

    function test_unapproveManager_notOwner() public {
        vm.startPrank(nonOwner);

        vm.expectRevert(UNAUTHORIZED);
        treasuryManagerFactory.unapproveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_unapproveManager_unknownManager() public {
        vm.expectRevert(TreasuryManagerFactory.UnknownManagerImplemention.selector);
        treasuryManagerFactory.unapproveManager(managerImplementation);

        vm.stopPrank();
    }

    function test_deployManager() public {
        treasuryManagerFactory.approveManager(managerImplementation);

        // We know the address in advance for this test, so we can assert the expected value
        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerDeployed(0x514dd0Bcaf5994Ef889f482B79d39D18B6E4363F, managerImplementation);

        // Deploy our new manager
        address payable _manager = treasuryManagerFactory.deployManager(managerImplementation);

        // Confirm that the implementation is as expected
        assertEq(treasuryManagerFactory.managerImplementation(_manager), managerImplementation);

        // Ensure that we can initialize our manager after deployment
        TreasuryManagerMock(_manager).initialize(address(this), data);
        vm.stopPrank();
    }

    function test_deployManager_notApproved() public {
        vm.expectRevert(TreasuryManagerFactory.UnknownManagerImplemention.selector);
        treasuryManagerFactory.deployManager(managerImplementation);
    }

    function test_deployManager_cannotInitializeMultipleTimes() public {
        treasuryManagerFactory.approveManager(managerImplementation);
        address payable _manager = treasuryManagerFactory.deployManager(managerImplementation);

        TreasuryManagerMock(_manager).initialize(address(this), data);

        vm.expectRevert();
        TreasuryManagerMock(_manager).initialize(address(this), data);
    }
}
