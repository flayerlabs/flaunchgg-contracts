// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {BurnTokensAction, ITreasuryAction} from '@flaunch/treasury/actions/BurnTokens.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from '../../FlaunchTest.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract BurnTokensActionTest is FlaunchTest {
    PoolKey poolKey;
    BurnTokensAction action;
    MemecoinTreasury memecoinTreasury;

    address memecoin;

    function setUp() public {
        _deployPlatform();

        // Flaunch a new token
        memecoin = positionManager.flaunch(
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

        // Get our Treasury contract
        memecoinTreasury = MemecoinTreasury(IMemecoin(memecoin).treasury());

        poolKey = positionManager.poolKey(memecoin);

        // Deploy our action
        action = new BurnTokensAction(positionManager.nativeToken());

        // Approve our action in the ActionManager
        positionManager.actionManager().approveAction(address(action));
    }

    function test_CanGetConstructorVariables() public view {
        assertEq(Currency.unwrap(action.nativeToken()), positionManager.nativeToken());
    }

    function test_CanBurnZeroTokens() public {
        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, 0, 0);

        memecoinTreasury.executeAction(address(action), '');
    }

    function test_CanBurnTokens() public {
        uint _amount = supplyShare(50);

        // Deal the tokens to the Treasury
        deal(memecoin, address(memecoinTreasury), _amount);

        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, 0, -int(_amount));

        memecoinTreasury.executeAction(address(action), '');
    }
}
