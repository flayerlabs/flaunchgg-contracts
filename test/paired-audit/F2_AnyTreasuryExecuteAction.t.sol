// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {AnyMemecoinTreasury} from '@flaunch/treasury/AnyMemecoinTreasury.sol';
import {BlankAction} from '@flaunch/treasury/actions/Blank.sol';

import {ERC20Mock} from 'test/tokens/ERC20Mock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IAnyPositionManager} from '@flaunch-interfaces/IAnyPositionManager.sol';
import {IMemecoinTreasury} from '@flaunch-interfaces/IMemecoinTreasury.sol';

/**
 * Regression coverage for audit finding F-2.
 *
 * Any pools import a plain ERC20 that does not implement `creator()`. The native
 * {MemecoinTreasury} resolved the pool creator by calling `memecoin.creator()`, which reverted
 * for these tokens and permanently locked the treasury. The Any path now deploys an
 * {AnyMemecoinTreasury} that resolves the creator through the {AnyFlaunch} contract instead.
 */
contract F2AnyTreasuryExecuteActionTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    BlankAction internal blankAction;
    address internal memecoin;
    AnyMemecoinTreasury internal treasury;

    function setUp() public {
        _deployPlatform();

        // The action that the creator will execute against the treasury
        blankAction = new BlankAction();

        // A plain ERC20 with no `creator()` selector, imported via the AnyPositionManager
        memecoin = address(new ERC20Mock(address(this)));

        anyPositionManager.approveCreator(address(this), true);
        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // The Any pool's treasury is an {AnyMemecoinTreasury} clone
        treasury = AnyMemecoinTreasury(anyFlaunch.memecoinTreasury(memecoin));
    }

    /**
     * The imported memecoin genuinely lacks a `creator()` selector, so the old native resolution
     * path (`memecoin.creator()`) would have reverted. The Any manager instead resolves the
     * creator from the Flaunch NFT owner.
     */
    function test_F2_MemecoinHasNoCreatorSelectorButAnyFlaunchResolvesCreator() public {
        (bool success,) = memecoin.staticcall(abi.encodeWithSignature('creator()'));
        assertFalse(success, 'ERC20Mock unexpectedly implements creator()');

        assertEq(anyFlaunch.creator(memecoin), address(this), 'creator not resolved via AnyFlaunch');
    }

    /**
     * The Flaunch-NFT holder (creator) can execute an approved action on the Any pool treasury.
     * Before the fix this reverted on the missing `creator()` selector.
     */
    function test_F2_ExecuteActionSucceedsForAnyPool() public {
        // Route some value into the treasury (direct flETH transfer, mimicking a
        // BidWall-disabled fee routing that lands flETH in the treasury)
        deal(address(WETH), address(this), 1 ether);
        WETH.transfer(address(treasury), 1 ether);

        // Approve the action so it can be executed
        actionManager.approveAction(address(blankAction));

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);

        // The action executes successfully (creator resolved through AnyFlaunch)
        vm.expectEmit();
        emit IMemecoinTreasury.ActionExecuted(address(blankAction), poolKey, '');
        treasury.executeAction(address(blankAction), '');
    }

    /**
     * A caller that is not the resolved creator is rejected with `Unauthorized`, proving the
     * creator resolution (not a blanket bypass) still gates the treasury.
     */
    function test_F2_ExecuteActionUnauthorizedForNonCreator(
        address _caller
    ) public {
        vm.assume(_caller != address(this));

        actionManager.approveAction(address(blankAction));

        vm.prank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        treasury.executeAction(address(blankAction), '');
    }
}
