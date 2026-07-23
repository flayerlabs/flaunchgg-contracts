// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlayBurner} from '@flaunch/libraries/FlayBurner.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract FlayBurnerTest is FlaunchTest {
    address owner;
    address user;

    address payable burnerAddress;

    function setUp() public {
        _deployPlatform();

        owner = address(this);
        user = address(0x123);

        burnerAddress = payable(address(0x456));

        // Make sure contract starts with no burner set
        assertEq(flayBurner.burner(), address(0));
    }

    function test_Constructor() public view {
        assertEq(address(flayBurner.fleth()), address(flETH));
    }

    function test_CanSetBurner(
        address payable _burner
    ) public {
        vm.expectEmit(true, true, false, false);
        emit FlayBurner.BurnerUpdated(_burner);

        flayBurner.setBurner(_burner);
        assertEq(flayBurner.burner(), _burner);
    }

    function test_CanBuyAndBurnIfNoBurnerSet(
        uint _amount
    ) public {
        vm.startPrank(user);

        // Deposit some ETH -> flETH to the user
        deal(user, _amount);
        flETH.deposit{value: _amount}();

        // User approves transfer
        flETH.approve(address(flayBurner), _amount);

        // Send tokens while no burner is set
        flayBurner.buyAndBurn(_amount);

        // Contract should hold the tokens
        assertEq(flETH.balanceOf(address(flayBurner)), _amount);
        assertEq(flETH.balanceOf(user), 0);
        vm.stopPrank();
    }

    function test_CanBuyAndBurn(
        uint _amount,
        uint _sendAmount
    ) public {
        vm.assume(_sendAmount < _amount);

        vm.startPrank(user);

        // Deposit some ETH -> flETH to the user
        deal(user, _amount);
        flETH.deposit{value: _amount}();

        flETH.approve(address(flayBurner), _amount);

        // Set burner
        vm.stopPrank();
        flayBurner.setBurner(burnerAddress);

        // User sends tokens
        vm.startPrank(user);
        flayBurner.buyAndBurn(_sendAmount);
        vm.stopPrank();

        // Tokens should go to the burner
        assertEq(flETH.balanceOf(burnerAddress), _sendAmount);
        assertEq(flETH.balanceOf(address(flayBurner)), 0);
        assertEq(flETH.balanceOf(user), _amount - _sendAmount);
    }

    function test_CanBuyAndBurnBalanceOfSelf(
        uint _amount
    ) public {
        vm.startPrank(user);

        // Deposit some ETH -> flETH to the user
        deal(user, _amount);
        flETH.deposit{value: _amount}();

        flETH.approve(address(flayBurner), _amount);

        // Set burner
        vm.stopPrank();
        flayBurner.setBurner(burnerAddress);

        // User executes buyAndBurnBalanceOfSelf
        vm.startPrank(user);
        flayBurner.buyAndBurnBalanceOfSelf();
        vm.stopPrank();

        assertEq(flETH.balanceOf(burnerAddress), _amount);
        assertEq(flETH.balanceOf(address(flayBurner)), 0);
        assertEq(flETH.balanceOf(user), 0);
    }

    function test_CanSendEthAndIsConvertedToFleth(
        uint64 _amount
    ) public {
        vm.assume(_amount != 0);

        deal(user, _amount);

        (bool sent,) = payable(address(flayBurner)).call{value: _amount}('');
        assertTrue(sent);

        assertEq(payable(address(flayBurner)).balance, 0);
        assertEq(flETH.balanceOf(address(flayBurner)), _amount);
    }
}
