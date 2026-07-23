// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TreasuryActionManager} from '@flaunch/treasury/ActionManager.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {BlankAction} from '@flaunch/treasury/actions/Blank.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IMemecoinTreasury} from '@flaunch-interfaces/IMemecoinTreasury.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract MemecoinTreasuryTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    BlankAction internal blankAction;
    MemecoinTreasury internal memecoinTreasury;

    address internal token;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // Register our blank action
        blankAction = new BlankAction();

        token = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Load our MemecoinTreasury
        memecoinTreasury = MemecoinTreasury(flaunch.memecoinTreasury(1));
    }

    function test_CanExecuteAction(
        bytes memory _data
    ) public {
        // Approve the action
        actionManager.approveAction(address(blankAction));

        PoolKey memory poolKey = positionManager.poolKey(token);

        // Execute the action
        vm.expectEmit();
        emit IMemecoinTreasury.ActionExecuted(address(blankAction), poolKey, _data);
        memecoinTreasury.executeAction(address(blankAction), _data);
    }

    function test_CannotExecuteUnapprovedAction(
        bytes memory _data
    ) public {
        // Execute the action
        vm.expectRevert(IMemecoinTreasury.ActionNotApproved.selector);
        memecoinTreasury.executeAction(address(blankAction), _data);
    }

    function test_CannotExecuteActionWithoutTokenHolding(
        address _caller,
        bytes memory _data
    ) public {
        vm.assume(_caller != address(this));

        // Approve the action
        actionManager.approveAction(address(blankAction));

        vm.startPrank(_caller);

        // Execute the action
        vm.expectRevert(UNAUTHORIZED);
        memecoinTreasury.executeAction(address(blankAction), _data);

        vm.stopPrank();
    }

    function test_CanClaimFees_NoFlthAdded() public {
        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Call claimFees
        memecoinTreasury.claimFees();

        // Check that ETH balance has not changed
        assertEq(WETH.balanceOf(address(memecoinTreasury)), initialBalance, 'ETH should not have been added');
    }

    function test_CanClaimFees_FlethAdded(
        uint _flethAdded
    ) public {
        // Provide sufficient flETH to fund it
        deal(address(WETH), address(feeDistributorMock), _flethAdded);

        // Set the {PositionManager} fees for {MemecoinTreasury} to a positive amount
        vm.assume(_flethAdded > 0);
        feeDistributorMock.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')), _recipient: payable(address(memecoinTreasury)), _amount: _flethAdded
        });

        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Call claimFees
        memecoinTreasury.claimFees();

        // Check that ETH balance increased by the expected amount
        assertEq(WETH.balanceOf(address(memecoinTreasury)), initialBalance + _flethAdded, 'flETH should have been added');
    }

    function test_CanClaimFeesDuringTransaction(
        uint _flethAdded
    ) public {
        // Provide sufficient native token to the {PositionManager}
        deal(address(WETH), address(feeDistributorMock), _flethAdded);

        // Set the {PositionManager} fees for {MemecoinTreasury} to a positive amount
        vm.assume(_flethAdded > 0);
        feeDistributorMock.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')), _recipient: payable(address(memecoinTreasury)), _amount: _flethAdded
        });

        // Record initial balance
        uint initialBalance = WETH.balanceOf(address(memecoinTreasury));

        // Approve our blank action and execute it, which should claim the fees
        actionManager.approveAction(address(blankAction));
        memecoinTreasury.executeAction(address(blankAction), '');

        // Check that ETH balance increased by the expected amount
        assertEq(WETH.balanceOf(address(memecoinTreasury)), initialBalance + _flethAdded, 'flETH should have been added');
    }
}
