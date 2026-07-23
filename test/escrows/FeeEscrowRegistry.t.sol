// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';
import {FeeEscrowRegistry} from '@flaunch/escrows/FeeEscrowRegistry.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IFeeEscrowRegistry} from '@flaunch-interfaces/IFeeEscrowRegistry.sol';

/**
 * Comprehensive test suite for FeeEscrowRegistry contract
 */
contract FeeEscrowRegistryTest is FlaunchTest {
    // Test contracts
    FeeEscrowRegistry public registry;
    FeeEscrow public feeEscrow1;
    FeeEscrow public feeEscrow2;
    FeeEscrow public feeEscrow3;
    FeeEscrow public feeEscrow4;

    // Test addresses
    address public owner;
    address public nonOwner;
    address public recipient;

    // Test data
    PoolId public testPoolId;
    uint public constant FEE_AMOUNT_1 = 1 ether;
    uint public constant FEE_AMOUNT_2 = 2.5 ether;
    uint public constant FEE_AMOUNT_3 = 0.5 ether;
    uint public constant FEE_AMOUNT_4 = 0; // No fees

    function setUp() public {
        // Deploy our platform
        _deployPlatform();

        // Set up test addresses
        owner = address(this);
        nonOwner = address(0x123);
        recipient = address(0x999);

        // Deploy the registry
        registry = new FeeEscrowRegistry();

        // Deploy test fee escrows
        feeEscrow1 = new FeeEscrow(address(flETH), address(indexer));
        feeEscrow2 = new FeeEscrow(address(flETH), address(indexer));
        feeEscrow3 = new FeeEscrow(address(flETH), address(indexer));
        feeEscrow4 = new FeeEscrow(address(flETH), address(indexer));

        // Set up test pool ID
        testPoolId = PoolId.wrap(bytes32('test-pool-id'));

        // Fund escrows with fees
        _fundEscrow(feeEscrow1, FEE_AMOUNT_1);
        _fundEscrow(feeEscrow2, FEE_AMOUNT_2);
        _fundEscrow(feeEscrow3, FEE_AMOUNT_3);
        // feeEscrow4 has no fees (FEE_AMOUNT_4 = 0)
    }

    function test_Constructor_SetsOwnerCorrectly() public {
        assertEq(registry.owner(), owner);
    }

    function test_Constructor_InitializesEmptyRegistry() public {
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 0);
    }

    function test_AddFeeEscrow_OwnerCanAddEscrow() public {
        // Add first escrow as a non-legacy escrow
        vm.expectEmit();
        emit IFeeEscrowRegistry.FeeEscrowAdded(address(feeEscrow1), false);

        registry.addFeeEscrow(address(feeEscrow1), false);

        // Verify escrow was added
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 1);
        assertEq(escrows[0], address(feeEscrow1));
    }

    function test_AddFeeEscrow_OwnerCanAddLegacyEscrow() public {
        // Add first escrow as a legacy escrow
        vm.expectEmit();
        emit IFeeEscrowRegistry.FeeEscrowAdded(address(feeEscrow1), true);

        registry.addFeeEscrow(address(feeEscrow1), true);

        // Verify escrow was added
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 1);
        assertEq(escrows[0], address(feeEscrow1));
    }

    function test_AddFeeEscrow_NonOwnerCannotAddEscrow() public {
        vm.startPrank(nonOwner);
        vm.expectRevert();
        registry.addFeeEscrow(address(feeEscrow1), false);
        vm.stopPrank();

        // Verify escrow was not added
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 0);
    }

    function test_AddFeeEscrow_CanAddMultipleEscrows() public {
        // Add multiple escrows
        registry.addFeeEscrow(address(feeEscrow1), false);
        registry.addFeeEscrow(address(feeEscrow2), false);
        registry.addFeeEscrow(address(feeEscrow3), false);

        // Verify all escrows were added
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 3);

        // Verify all addresses are present (order may vary)
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;

        for (uint i = 0; i < escrows.length; i++) {
            if (escrows[i] == address(feeEscrow1)) {
                found1 = true;
            }
            if (escrows[i] == address(feeEscrow2)) {
                found2 = true;
            }
            if (escrows[i] == address(feeEscrow3)) {
                found3 = true;
            }
        }

        assertTrue(found1 && found2 && found3, 'All escrows should be found');
    }

    function test_AddFeeEscrow_AddingSameEscrowTwiceDoesNotDuplicate() public {
        // Add escrow twice
        registry.addFeeEscrow(address(feeEscrow1), false);
        registry.addFeeEscrow(address(feeEscrow1), false);

        // Verify escrow appears only once
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 1);
        assertEq(escrows[0], address(feeEscrow1));
    }

    function test_RemoveFeeEscrow_OwnerCanRemoveEscrow() public {
        // First add the escrow
        registry.addFeeEscrow(address(feeEscrow1), false);

        // Then remove it
        vm.expectEmit(true, false, false, true);
        emit IFeeEscrowRegistry.FeeEscrowRemoved(address(feeEscrow1));

        registry.removeFeeEscrow(address(feeEscrow1));

        // Verify escrow was removed
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 0);
    }

    function test_RemoveFeeEscrow_NonOwnerCannotRemoveEscrow() public {
        // First add the escrow as owner
        registry.addFeeEscrow(address(feeEscrow1), false);

        // Try to remove as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert();
        registry.removeFeeEscrow(address(feeEscrow1));
        vm.stopPrank();

        // Verify escrow was not removed
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 1);
        assertEq(escrows[0], address(feeEscrow1));
    }

    function test_RemoveFeeEscrow_RemovingNonExistentEscrowDoesNothing() public {
        // Try to remove escrow that was never added
        registry.removeFeeEscrow(address(feeEscrow1));

        // Verify registry is still empty
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 0);
    }

    function test_RemoveFeeEscrow_CanRemoveFromMultipleEscrows() public {
        // Add multiple escrows
        registry.addFeeEscrow(address(feeEscrow1), false);
        registry.addFeeEscrow(address(feeEscrow2), false);
        registry.addFeeEscrow(address(feeEscrow3), false);

        // Remove one escrow
        registry.removeFeeEscrow(address(feeEscrow2));

        // Verify only 2 escrows remain
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 2);

        // Verify the removed escrow is not present
        bool found2 = false;
        for (uint i = 0; i < escrows.length; i++) {
            if (escrows[i] == address(feeEscrow2)) {
                found2 = true;
            }
        }
        assertFalse(found2, 'Removed escrow should not be found');
    }

    function test_FeeEscrows_ReturnsEmptyArrayWhenNoEscrows() public {
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 0);
    }

    function test_FeeEscrows_ReturnsAllRegisteredEscrows() public {
        // Add multiple escrows
        registry.addFeeEscrow(address(feeEscrow1), false);
        registry.addFeeEscrow(address(feeEscrow2), false);
        registry.addFeeEscrow(address(feeEscrow3), false);

        // Get escrows
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 3);

        // Verify all addresses are present
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;

        for (uint i = 0; i < escrows.length; i++) {
            if (escrows[i] == address(feeEscrow1)) {
                found1 = true;
            }
            if (escrows[i] == address(feeEscrow2)) {
                found2 = true;
            }
            if (escrows[i] == address(feeEscrow3)) {
                found3 = true;
            }
        }

        assertTrue(found1 && found2 && found3, 'All escrows should be found');
    }

    function test_FeeEscrows_ReturnsUpdatedListAfterRemoval() public {
        // Add multiple escrows
        registry.addFeeEscrow(address(feeEscrow1), false);
        registry.addFeeEscrow(address(feeEscrow2), false);
        registry.addFeeEscrow(address(feeEscrow3), false);

        // Remove one escrow
        registry.removeFeeEscrow(address(feeEscrow2));

        // Get updated escrows
        address[] memory escrows = registry.feeEscrows();
        assertEq(escrows.length, 2);

        // Verify removed escrow is not present
        bool found2 = false;
        for (uint i = 0; i < escrows.length; i++) {
            if (escrows[i] == address(feeEscrow2)) {
                found2 = true;
            }
        }
        assertFalse(found2, 'Removed escrow should not be found');
    }

    function test_Integration_AddRemoveAddCycle() public {
        // Add escrow
        registry.addFeeEscrow(address(feeEscrow1), false);
        assertEq(registry.feeEscrows().length, 1);

        // Remove escrow
        registry.removeFeeEscrow(address(feeEscrow1));
        assertEq(registry.feeEscrows().length, 0);

        // Add escrow again
        registry.addFeeEscrow(address(feeEscrow1), false);
        assertEq(registry.feeEscrows().length, 1);
    }

    function _fundEscrow(
        FeeEscrow _escrow,
        uint _amount
    ) internal {
        if (_amount > 0) {
            // Mint flETH to this contract
            deal(address(flETH), address(this), _amount);

            // Approve escrow to spend flETH
            IERC20(address(flETH)).approve(address(_escrow), _amount);

            // Allocate fees to the escrow
            _escrow.allocateFees(testPoolId, address(this), _amount);
        }
    }
}
