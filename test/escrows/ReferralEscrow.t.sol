// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {ReferralEscrow} from '@flaunch/escrows/ReferralEscrow.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {ERC20Mock} from '../tokens/ERC20Mock.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {IReferralEscrow} from '@flaunch-interfaces/IReferralEscrow.sol';

contract ReferralEscrowTest is FlaunchTest {
    address owner = address(this);
    address nonOwner = address(0x123);

    address payable user1 = payable(address(0x456));
    address payable user2 = payable(address(0x789));

    ERC20Mock token1;
    ERC20Mock token2;

    PoolId POOL_ID = PoolId.wrap(bytes32('POOL1'));

    function setUp() public {
        _deployPlatform();

        // Flaunch 3 pools and wait sufficient time to bypass Fair Launch
        token1 = ERC20Mock(_flaunchMock('token1'));
        token2 = ERC20Mock(_flaunchMock('token2'));

        vm.warp(block.timestamp + 1 days);
    }

    // --- Ownable Functionality ---

    function test_CanSetPoolSwapByOwner() public {
        address newPoolSwap = address(0x111);

        // Call updatePoolSwap as owner and check if successful
        referralEscrow.setPoolSwap(newPoolSwap);
        assertEq(address(referralEscrow.poolSwap()), newPoolSwap, 'PoolSwap should be updated by owner');
    }

    function test_CannotSetPoolSwapWhenNotOwner() public {
        address newPoolSwap = address(0x222);

        // Attempt to updatePoolSwap as non-owner
        vm.prank(nonOwner);
        vm.expectRevert(UNAUTHORIZED);
        referralEscrow.setPoolSwap(newPoolSwap);
    }

    // --- Event Emissions ---

    function test_AssignTokensEmitsEvent() public {
        uint amount = 1000;

        // Expect TokensAssigned event to be emitted
        vm.expectEmit();
        emit IReferralEscrow.TokensAssigned(POOL_ID, user1, address(token1), amount);

        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount);
    }

    function test_ClaimTokensEmitsEvent() public {
        uint amount = 500;

        // Set up allocation and trigger claim
        deal(address(token1), address(referralEscrow), amount);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount);

        vm.startPrank(user1);

        // Expect TokensClaimed event to be emitted
        vm.expectEmit();
        emit IReferralEscrow.TokensClaimed(user1, user1, address(token1), amount);

        _claimSingleToken(token1, user1);
        vm.stopPrank();
    }

    // --- Assign Tokens ---

    function test_CanAssignTokens(
        address _recipient,
        uint128 _amount1,
        uint128 _amount2
    ) public {
        vm.startPrank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, _recipient, address(token1), _amount1);

        assertEq(referralEscrow.allocations(_recipient, address(token1)), _amount1, 'Incorrect token1 allocation');
        assertEq(referralEscrow.allocations(_recipient, address(token2)), 0, 'Incorrect token2 allocation');

        referralEscrow.assignTokens(POOL_ID, _recipient, address(token1), _amount2);
        referralEscrow.assignTokens(POOL_ID, _recipient, address(token2), _amount2);

        assertEq(referralEscrow.allocations(_recipient, address(token1)), uint(_amount1) + _amount2, 'Incorrect token1 allocation');
        assertEq(referralEscrow.allocations(_recipient, address(token2)), _amount2, 'Incorrect token2 allocation');

        vm.stopPrank();
    }

    function test_CannotAssignTokensAsNonPositionManager() public {
        vm.expectRevert(IReferralEscrow.NotPositionManager.selector);
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), 1 ether);
    }

    // --- Fuzz Testing: One Token Claims ---

    function test_Fuzz_CanClaimSingleToken(
        uint amount
    ) public {
        vm.assume(amount > 0 && amount < 1e18); // Limit to reasonable range

        // Assign token and claim it
        deal(address(token1), address(referralEscrow), amount);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount);

        vm.startPrank(user1);

        uint initialBalance = token1.balanceOf(user1);

        _claimSingleToken(token1, user1);

        // Check balance and allocation after claim
        assertEq(token1.balanceOf(user1), initialBalance + amount, 'Balance mismatch after claim');
        assertEq(referralEscrow.allocations(user1, address(token1)), 0, 'Allocation should be zero after claim');

        vm.stopPrank();
    }

    function test_CanClaimSingleTokenMaxAmount() public {
        // We need to limit to uint224 due to Vote delegation limits
        uint amount = type(uint224).max;

        // Assign token and claim it
        deal(address(token1), address(referralEscrow), amount);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount);

        vm.startPrank(user1);

        uint initialBalance = token1.balanceOf(user1);

        _claimSingleToken(token1, user1);

        // Check balance and allocation after claim
        assertEq(token1.balanceOf(user1), initialBalance + amount, 'Balance mismatch after max claim');
        assertEq(referralEscrow.allocations(user1, address(token1)), 0, 'Allocation should be zero after max claim');

        vm.stopPrank();
    }

    // --- Fuzz Testing: Multiple Token Claims ---

    function test_Fuzz_CanClaimMultipleTokens(
        uint224 amount1,
        uint224 amount2
    ) public {
        vm.assume(amount1 > 0 && amount2 > 0);

        deal(address(token1), address(referralEscrow), amount1);
        deal(address(token2), address(referralEscrow), amount2);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount1);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token2), amount2);

        vm.startPrank(user1);

        uint initialBalance1 = token1.balanceOf(user1);
        uint initialBalance2 = token2.balanceOf(user1);

        _claimMultipleTokens(token1, token2, user1);

        // Verify balances and allocations after claim
        assertEq(token1.balanceOf(user1), initialBalance1 + amount1, 'token1 balance mismatch');
        assertEq(token2.balanceOf(user1), initialBalance2 + amount2, 'token2 balance mismatch');
        assertEq(referralEscrow.allocations(user1, address(token1)), 0, 'token1 allocation should be zero');
        assertEq(referralEscrow.allocations(user1, address(token2)), 0, 'token2 allocation should be zero');

        vm.stopPrank();
    }

    function test_Fuzz_CanClaimMultipleTokensWithMaxAmounts() public {
        // We need to limit to uint224 due to Vote delegation limits
        uint amount1 = type(uint224).max;
        uint amount2 = type(uint224).max;

        deal(address(token1), address(referralEscrow), amount1);
        deal(address(token2), address(referralEscrow), amount2);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount1);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token2), amount2);

        vm.startPrank(user1);

        uint initialBalance1 = token1.balanceOf(user1);
        uint initialBalance2 = token2.balanceOf(user1);

        _claimMultipleTokens(token1, token2, user1);

        // Verify balances and allocations after max claim
        assertEq(token1.balanceOf(user1), initialBalance1 + amount1, 'token1 max balance mismatch');
        assertEq(token2.balanceOf(user1), initialBalance2 + amount2, 'token2 max balance mismatch');
        assertEq(referralEscrow.allocations(user1, address(token1)), 0, 'token1 allocation should be zero');
        assertEq(referralEscrow.allocations(user1, address(token2)), 0, 'token2 allocation should be zero');

        vm.stopPrank();
    }

    function test_CanClaimForAnotherRecipient(
        uint224 amount1,
        uint224 amount2
    ) public {
        vm.assume(amount1 > 0 && amount2 > 0);

        deal(address(token1), address(referralEscrow), amount1);
        deal(address(token2), address(referralEscrow), amount2);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token1), amount1);
        vm.prank(address(positionManager));
        referralEscrow.assignTokens(POOL_ID, user1, address(token2), amount2);

        vm.startPrank(user1);

        uint initialBalance1 = token1.balanceOf(user1);
        uint initialBalance2 = token2.balanceOf(user1);

        _claimMultipleTokens(token1, token2, user2);

        // Verify balances and allocations after claim
        assertEq(token1.balanceOf(user2), initialBalance1 + amount1, 'token1 balance mismatch');
        assertEq(token2.balanceOf(user2), initialBalance2 + amount2, 'token2 balance mismatch');
        assertEq(referralEscrow.allocations(user1, address(token1)), 0, 'token1 allocation should be zero');
        assertEq(referralEscrow.allocations(user1, address(token2)), 0, 'token2 allocation should be zero');

        vm.stopPrank();
    }

    function _flaunchMock(
        string memory _name
    ) internal returns (address) {
        return positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: _name,
                symbol: _name,
                tokenUri: '',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 10_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function _claimSingleToken(
        ERC20Mock _token,
        address payable _recipient
    ) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(_token);
        referralEscrow.claimTokens(tokens, _recipient);
    }

    function _claimMultipleTokens(
        ERC20Mock _token1,
        ERC20Mock _token2,
        address payable _recipient
    ) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(_token1);
        tokens[1] = address(_token2);

        referralEscrow.claimTokens(tokens, _recipient);
    }

    function _createEthPosition(
        address _token
    ) internal {
        uint amount = 1 ether;

        deal(address(this), amount);
        flETH.deposit{value: amount}();
        flETH.approve(address(poolSwap), amount);

        // Action our swap
        bool flipped = _token < address(flETH);
        poolSwap.swap(
            PoolKey({
                currency0: Currency.wrap(flipped ? _token : address(flETH)),
                currency1: Currency.wrap(flipped ? address(flETH) : _token),
                fee: 0,
                hooks: IHooks(positionManager),
                tickSpacing: 60
            }),
            SwapParams({
                zeroForOne: !flipped,
                amountSpecified: -int(amount),
                sqrtPriceLimitX96: !flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }
}
