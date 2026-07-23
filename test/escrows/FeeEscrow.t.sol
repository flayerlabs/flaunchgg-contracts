// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IFeeEscrow} from '@flaunch-interfaces/IFeeEscrow.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract FeeEscrowTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    // Set a test-wide pool key and pool ID
    PoolKey private _poolKey;
    PoolId private _poolId;

    // Store our memecoin created for the test
    address memecoin;

    // Mock FLETH token for testing
    address mockFLETH;

    // Standalone FeeEscrow for direct testing
    FeeEscrow private _feeEscrow;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 20_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );

        // Reference our `_poolKey` and `_poolId` for later tests
        _poolKey = positionManager.poolKey(memecoin);
        _poolId = _poolKey.toId();

        // Skip FairLaunch

        // Create a standalone FeeEscrow instance for direct testing
        _feeEscrow = new FeeEscrow(address(flETH), address(indexer));
    }

    function test_AllocateFees(
        address _recipient,
        uint _amount
    ) public {
        // Validate the recipient address
        vm.assume(_recipient != address(0));
        // Limit amount to a reasonable value
        vm.assume(_amount > 0 && _amount < 1000 ether);

        // Mint flETH to the test contract
        deal(address(flETH), address(this), _amount);

        // Approve FeeEscrow to transfer
        IERC20(address(flETH)).approve(address(_feeEscrow), _amount);

        // Expect the Deposit event
        vm.expectEmit();
        emit IFeeEscrow.Deposit(_poolId, _recipient, address(flETH), _amount);

        // Allocate fees
        _feeEscrow.allocateFees(_poolId, _recipient, _amount);

        // Verify balance updated
        assertEq(_feeEscrow.balances(_recipient), _amount, 'Balance not updated correctly');
    }

    function test_AllocateFeesWithZeroAmount(
        address _recipient
    ) public {
        // Validate the recipient address
        vm.assume(_recipient != address(0));

        // Initial balance should be zero
        assertEq(_feeEscrow.balances(_recipient), 0, 'Initial balance should be zero');

        // Allocate zero fees - should not change anything
        _feeEscrow.allocateFees(_poolId, _recipient, 0);

        // Balance should remain zero
        assertEq(_feeEscrow.balances(_recipient), 0, 'Balance should still be zero after zero allocation');
    }

    function test_CannotAllocateFeesToZeroAddress() public {
        // Try to allocate to zero address, should revert
        vm.expectRevert(IFeeEscrow.RecipientZeroAddress.selector);
        _feeEscrow.allocateFees(_poolId, address(0), 1);
    }

    function test_WithdrawFees(
        uint _amount,
        bool _unwrap
    ) public {
        // Create valid addresses for testing
        address payable _sender = payable(makeAddr('_sender'));
        address payable _recipient = payable(makeAddr('_recipient'));

        // Limit amount to a reasonable value
        vm.assume(_amount > 0 && _amount < 1000 ether);

        // Mint flETH to this contract for allocation
        deal(address(flETH), address(this), _amount);

        // Approve FeeEscrow to transfer
        IERC20(address(flETH)).approve(address(_feeEscrow), _amount);

        // Allocate fees to the sender
        _feeEscrow.allocateFees(_poolId, _sender, _amount);

        // For unwrap tests, prepare the flETH contract with ETH
        if (_unwrap) {
            // Fund the flETH contract to allow withdrawals
            deal(address(flETH), _amount);
        }

        // Expect Withdrawal event
        vm.expectEmit();
        emit IFeeEscrow.Withdrawal(_sender, _recipient, _unwrap ? address(0) : address(flETH), _amount);

        // Withdraw as sender to recipient
        vm.prank(_sender);
        _feeEscrow.withdrawFees(_recipient, _unwrap);

        // Verify sender's balance is zero after withdrawal
        assertEq(_feeEscrow.balances(_sender), 0, 'Sender balance should be zero after withdrawal');

        // Verify recipient received the tokens
        if (_unwrap) {
            assertEq(_recipient.balance, _amount, 'Recipient did not receive correct amount of ETH');
        } else {
            assertEq(IERC20(address(flETH)).balanceOf(_recipient), _amount, 'Recipient did not receive correct amount of flETH');
        }
    }

    function test_WithdrawFeesWithZeroBalance(
        bool _unwrap
    ) public {
        // Create valid addresses for testing
        address payable _sender = payable(makeAddr('_sender'));
        address payable _recipient = payable(makeAddr('_recipient'));

        // Verify initial balance is zero
        assertEq(_feeEscrow.balances(_sender), 0, 'Initial balance should be zero');

        // Withdraw with zero balance - should not change anything
        vm.prank(_sender);
        _feeEscrow.withdrawFees(_recipient, _unwrap);

        // Balances should remain unchanged
        assertEq(_feeEscrow.balances(_sender), 0, 'Balance should still be zero after withdrawal');
    }

    function test_WithdrawFeesMultipleTimes(
        uint _amount
    ) public {
        // Create valid addresses for testing
        address payable _sender = payable(makeAddr('_sender'));
        address payable _recipient = payable(makeAddr('_recipient'));

        // Limit amount to a reasonable value
        vm.assume(_amount > 0 && _amount < 1000 ether);

        // Mint flETH to this contract for allocation
        deal(address(flETH), address(this), _amount * 2);

        // Approve FeeEscrow to transfer
        IERC20(address(flETH)).approve(address(_feeEscrow), _amount * 2);

        // Allocate fees to the sender
        _feeEscrow.allocateFees(_poolId, _sender, _amount);

        // First withdrawal
        vm.prank(_sender);
        _feeEscrow.withdrawFees(_recipient, false);

        // Verify balance is zero after first withdrawal
        assertEq(_feeEscrow.balances(_sender), 0, 'Sender balance should be zero after first withdrawal');

        // Make a second allocation
        _feeEscrow.allocateFees(_poolId, _sender, _amount);

        // Second withdrawal
        vm.prank(_sender);
        _feeEscrow.withdrawFees(_recipient, false);

        // Verify balance is zero after second withdrawal
        assertEq(_feeEscrow.balances(_sender), 0, 'Sender balance should be zero after second withdrawal');

        // Verify recipient received the total amount
        assertEq(IERC20(address(flETH)).balanceOf(_recipient), _amount * 2, 'Recipient did not receive correct total amount');
    }

    function test_CanReceiveEther() public {
        // Send ETH to the contract via the receive function
        (bool success,) = address(_feeEscrow).call{value: 1 ether}('');
        assertTrue(success, 'Failed to receive ETH');

        // Verify the contract received the ETH
        assertEq(address(_feeEscrow).balance, 1 ether, 'Contract did not receive ETH');
    }

    function test_AllocationFeeDeposit_Integration() public {
        // Create test addresses
        address recipient = makeAddr('recipient');
        uint amount = 1 ether;

        // Mint and approve flETH for the position manager
        deal(address(flETH), address(positionManager), amount);
        vm.prank(address(positionManager));
        IERC20(address(flETH)).approve(address(feeEscrow), amount);

        // Expect the deposit event
        vm.expectEmit();
        emit IFeeEscrow.Deposit(_poolId, recipient, address(flETH), amount);

        // Allocate fees through position manager mock (if available)
        vm.prank(address(positionManager));
        feeEscrow.allocateFees(_poolId, recipient, amount);

        // Verify allocation succeeded
        assertEq(feeEscrow.balances(recipient), amount, 'Fee allocation failed');
    }

    function test_Withdrawal_Integration() public {
        // Create test addresses
        address sender = makeAddr('sender');
        address payable recipient = payable(makeAddr('recipient'));
        uint amount = 1 ether;

        // Set up allocation first
        deal(address(flETH), address(positionManager), amount);
        vm.prank(address(positionManager));
        IERC20(address(flETH)).approve(address(feeEscrow), amount);

        vm.prank(address(positionManager));
        feeEscrow.allocateFees(_poolId, sender, amount);

        // For unwrapping to work, fund the flETH contract
        deal(address(flETH), amount);

        // Expect the withdrawal event (unwrapping)
        vm.expectEmit();
        emit IFeeEscrow.Withdrawal(sender, recipient, address(0), amount);

        // Withdraw fees with unwrapping
        vm.prank(sender);
        feeEscrow.withdrawFees(recipient, true);

        // Verify recipient received ETH
        assertEq(recipient.balance, amount, 'Withdrawal with unwrapping failed');
    }
}
