// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CustomFeeManagerRegistry} from '@flaunch/treasury/managers/partners/CustomFeeManagerRegistry.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract CustomFeeManagerRegistryTest is FlaunchTest {

    CustomFeeManagerRegistry public registry;

    address public owner;
    address public zeroAddress = address(0);

    event ManagerAdded(address indexed _manager);
    event ManagerRemoved(address indexed _manager);

    function setUp() public {
        owner = makeAddr('owner');

        vm.prank(owner);
        registry = new CustomFeeManagerRegistry();
    }

    function test_Constructor(address _unknownManager) public {
        // Check that the owner is set correctly
        assertEq(registry.owner(), owner);

        // Check that no managers are initially approved
        assertFalse(registry.isApprovedManager(_unknownManager));
    }

    function test_AddManager(address _manager) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        // Confirm that the manager is not already approved
        assertFalse(registry.isApprovedManager(_manager));

        // Confirm that we receive the expected event
        vm.expectEmit();
        emit ManagerAdded(_manager);

        // Add the manager as the contract owner
        vm.prank(owner);
        registry.addManager(_manager);

        // Confirm that the manager is now flagged as approved
        assertTrue(registry.isApprovedManager(_manager));
    }

    function test_AddManager_OnlyOwner(address _manager, address _nonOwner) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        // Ensure that the non-owner is not the owner
        vm.assume(_nonOwner != owner);
        
        vm.startPrank(_nonOwner);

        vm.expectRevert();
        registry.addManager(_manager);

        vm.stopPrank();
    }

    function test_AddManager_ZeroAddress() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(
            CustomFeeManagerRegistry.InvalidManager.selector,
            zeroAddress
        ));
        registry.addManager(zeroAddress);

        vm.stopPrank();
    }

    function test_AddManager_AlreadyAdded(address _manager) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        // Add the manager to the registry
        vm.prank(owner);
        registry.addManager(_manager);

        // Try to add the manager to the registry again, which should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            CustomFeeManagerRegistry.ManagerAlreadyAdded.selector,
            _manager
        ));
        registry.addManager(_manager);
    }

    function test_AddManager_MultipleManagers(address _manager1, address _manager2) public {
        // Ensure that the managers are not a zero address
        vm.assume(_manager1 != zeroAddress);
        vm.assume(_manager2 != zeroAddress);

        // Add the managers to the registry
        vm.startPrank(owner);
        registry.addManager(_manager1);
        registry.addManager(_manager2);
        vm.stopPrank();

        // Confirm that the managers are now flagged as approved
        assertTrue(registry.isApprovedManager(_manager1));
        assertTrue(registry.isApprovedManager(_manager2));
    }

    function test_RemoveManager(address _manager) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        // Add the manager to the registry
        vm.prank(owner);
        registry.addManager(_manager);

        // Confirm that the expected event is emitted
        vm.expectEmit();
        emit ManagerRemoved(_manager);

        // Then remove the manager from the registry
        vm.prank(owner);
        registry.removeManager(_manager);

        // Confirm that the manager is now flagged as not approved
        assertFalse(registry.isApprovedManager(_manager));
    }

    function test_RemoveManager_OnlyOwner(address _manager, address _nonOwner) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        // Ensure that the non-owner is not the owner
        vm.assume(_nonOwner != owner);
        
        // Add the manager to the registry
        vm.prank(owner);
        registry.addManager(_manager);

        // Try to remove the manager from the registry as non-owner, which should revert
        vm.startPrank(_nonOwner);

        vm.expectRevert();
        registry.removeManager(_manager);

        vm.stopPrank();
    }

    function test_RemoveManager_DoesNotExist(address _manager) public {
        vm.startPrank(owner);

        // Try to remove a manager that does not exist from the registry, which should revert
        vm.expectRevert(abi.encodeWithSelector(
            CustomFeeManagerRegistry.ManagerDoesNotExist.selector,
            _manager
        ));
        registry.removeManager(_manager);

        vm.stopPrank();
    }

    function test_RemoveManager_CannotRemoveAgain(address _manager) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        vm.startPrank(owner);

        // Add the manager to the registry
        registry.addManager(_manager);

        // Remove the manager from the registry
        registry.removeManager(_manager);

        // Try to remove again, which should revert
        vm.expectRevert(abi.encodeWithSelector(
            CustomFeeManagerRegistry.ManagerDoesNotExist.selector,
            _manager
        ));
        registry.removeManager(_manager);

        vm.stopPrank();
    }

    function test_AddManager_AfterRemoving(address _manager) public {
        // Ensure that the manager is not a zero address
        vm.assume(_manager != zeroAddress);

        vm.startPrank(owner);

        // Add the manager to the registry
        registry.addManager(_manager);
        assertTrue(registry.isApprovedManager(_manager));

        // Remove the manager from the registry
        registry.removeManager(_manager);
        assertFalse(registry.isApprovedManager(_manager));

        // Add the manager to the registry again
        registry.addManager(_manager);
        assertTrue(registry.isApprovedManager(_manager));

        vm.stopPrank();
    }

    function test_MultipleManagers_IndependentOperations(address _manager1, address _manager2) public {
        // Ensure that the managers are not a zero address
        vm.assume(_manager1 != zeroAddress);
        vm.assume(_manager2 != zeroAddress);

        vm.startPrank(owner);
        
        // Add both managers
        registry.addManager(_manager1);
        registry.addManager(_manager2);
        
        assertTrue(registry.isApprovedManager(_manager1));
        assertTrue(registry.isApprovedManager(_manager2));
        
        // Remove only manager1
        registry.removeManager(_manager1);
        
        assertFalse(registry.isApprovedManager(_manager1));
        assertTrue(registry.isApprovedManager(_manager2));
        
        vm.stopPrank();
    }

}
