// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {DistributeAction as DistributeActionContract, ITreasuryAction} from '@flaunch/treasury/actions/Distribute.sol';

import {IDistributeAction as DistributeAction} from '@flaunch-interfaces/IDistributeAction.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from '../../FlaunchTest.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract DistributeActionTest is FlaunchTest {
    PoolKey poolKey;
    DistributeActionContract action;
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

        // Reference our poolKey for the created memecoin
        poolKey = positionManager.poolKey(memecoin);

        // Deploy our action
        action = new DistributeActionContract(positionManager.nativeToken());

        // Approve our action in the ActionManager
        positionManager.actionManager().approveAction(address(action));

        // Provide the treasury with sufficient tokens to make the distributions
        deal(memecoin, address(memecoinTreasury), 10 ether);

        deal(address(this), 10 ether);
        flETH.deposit{value: 10 ether}();
        flETH.transfer(address(memecoinTreasury), 10 ether);
    }

    function test_CanGetConstructorVariables() public view {
        assertEq(Currency.unwrap(action.nativeToken()), positionManager.nativeToken());
    }

    function test_CannotDistributeNothing() public {
        vm.expectRevert();
        memecoinTreasury.executeAction(address(action), '');
    }

    function test_CanDistributeToken0() public {
        // Create 3 distributions
        DistributeAction.Distribution[] memory distributions = new DistributeAction.Distribution[](3);
        distributions[0] = _distribution(address(1), 1.0 ether, true);
        distributions[1] = _distribution(address(2), 2.0 ether, true);
        distributions[2] = _distribution(address(3), 2.5 ether, true);

        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, -5.5 ether, 0);

        memecoinTreasury.executeAction(address(action), abi.encode(distributions));

        // The token will have been sent as ETH, so no flETH token will be received
        assertEq(poolKey.currency0.balanceOf(address(1)), 0);
        assertEq(poolKey.currency0.balanceOf(address(2)), 0);
        assertEq(poolKey.currency0.balanceOf(address(3)), 0);

        assertEq(payable(address(1)).balance, 1.0 ether);
        assertEq(payable(address(2)).balance, 2.0 ether);
        assertEq(payable(address(3)).balance, 2.5 ether);
    }

    function test_CanDistributeToken1() public {
        // Create 3 distributions
        DistributeAction.Distribution[] memory distributions = new DistributeAction.Distribution[](3);
        distributions[0] = _distribution(address(1), 1.0 ether, false);
        distributions[1] = _distribution(address(2), 2.0 ether, false);
        distributions[2] = _distribution(address(3), 2.5 ether, false);

        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, 0, -5.5 ether);

        memecoinTreasury.executeAction(address(action), abi.encode(distributions));

        assertEq(poolKey.currency1.balanceOf(address(1)), 1.0 ether);
        assertEq(poolKey.currency1.balanceOf(address(2)), 2.0 ether);
        assertEq(poolKey.currency1.balanceOf(address(3)), 2.5 ether);
    }

    function test_CanDistributeToken0And1() public {
        // Create 3 distributions
        DistributeAction.Distribution[] memory distributions = new DistributeAction.Distribution[](3);
        distributions[0] = _distribution(address(1), 1.0 ether, true);
        distributions[1] = _distribution(address(1), 2.0 ether, false);
        distributions[2] = _distribution(address(3), 2.5 ether, true);

        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(poolKey, -3.5 ether, -2 ether);

        memecoinTreasury.executeAction(address(action), abi.encode(distributions));

        assertEq(poolKey.currency0.balanceOf(address(1)), 0);
        assertEq(poolKey.currency0.balanceOf(address(2)), 0);
        assertEq(poolKey.currency0.balanceOf(address(3)), 0);

        assertEq(payable(address(1)).balance, 1.0 ether);
        assertEq(payable(address(2)).balance, 0.0 ether);
        assertEq(payable(address(3)).balance, 2.5 ether);

        assertEq(poolKey.currency1.balanceOf(address(1)), 2.0 ether);
        assertEq(poolKey.currency1.balanceOf(address(2)), 0.0 ether);
        assertEq(poolKey.currency1.balanceOf(address(3)), 0.0 ether);
    }

    function test_CannotDistributeWithInsufficientTokens(
        bool _token0
    ) public {
        // Create 3 distributions
        DistributeAction.Distribution[] memory distributions = new DistributeAction.Distribution[](1);
        distributions[0] = _distribution(address(1), 100 ether, _token0);

        vm.expectRevert();
        memecoinTreasury.executeAction(address(action), abi.encode(distributions));
    }

    function _distribution(
        address _recipient,
        uint _amount,
        bool _token0
    ) internal pure returns (DistributeAction.Distribution memory) {
        return DistributeAction.Distribution({recipient: _recipient, token0: _token0, amount: _amount});
    }
}
