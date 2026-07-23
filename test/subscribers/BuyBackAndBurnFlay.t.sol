// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {BuyBackAndBurnFlay} from '@flaunch/subscribers/BuyBackAndBurnFlay.sol';

import {MemecoinMock} from 'test/mocks/MemecoinMock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IBuyBackAndBurnFlay} from '@flaunch-interfaces/IBuyBackAndBurnFlay.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract BuyBackAndBurnFlayTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for PoolManager;

    PoolKey poolKey;

    address alice = makeAddr('alice');
    address memecoinTreasury;

    MemecoinMock memecoin;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        address _memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );
        memecoin = MemecoinMock(_memecoin);

        uint tokenId = flaunch.tokenId(_memecoin);

        // Register the treasury
        memecoinTreasury = flaunch.memecoinTreasury(tokenId);
    }

    function setUp() public {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(flETH)),
            currency1: Currency.wrap(address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });

        // Attach our Notifier subscriber
        positionManager.notifier().subscribe(address(buyBackAndBurnFlay), '');
        buyBackAndBurnFlay.setPoolKey(poolKey);
    }

    function test_Can_ReceiveEthAndConvertToFleth() public {
        (bool success,) = address(buyBackAndBurnFlay).call{value: 1 ether}('');
        assertTrue(success);

        assertEq(payable(address(buyBackAndBurnFlay)).balance, 0);
        assertEq(flETH.balanceOf(address(buyBackAndBurnFlay)), 1 ether);
    }

    function test_Can_InitializePositionWithSwap() public poolHasLiquidity {
        // Confirm that the position is not currently initialized
        (bool isInitialized,,,,) = buyBackAndBurnFlay.positionInfo();
        assertFalse(isInitialized);

        // Transfer enough ETH to the subscriber that the position will trigger
        address(buyBackAndBurnFlay).call{value: 1 ether}('');

        // Make an arbritrary swap that will trigger the buy
        deal(address(flETH), address(this), 1 ether);
        flETH.approve(address(poolSwap), type(uint).max);
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // It should initialize the position, just below the current price
        (bool initialized, int24 tickLower, int24 tickUpper, uint spent, uint burned) = buyBackAndBurnFlay.positionInfo();
        assertTrue(initialized);
        assertEq(spent, 1 ether);
        assertEq(burned, 0);

        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(), owner: address(buyBackAndBurnFlay), tickLower: tickLower, tickUpper: tickUpper, salt: ''
        });

        // Position should now have sufficient liquidity
        assertGt(liquidity, 0);

        // Transfer ETH to the subscriber that will trigger again
        address(buyBackAndBurnFlay).call{value: 1.5 ether}('');

        // Make an arbritrary swap that will trigger the buy
        deal(address(flETH), address(this), 10 ether);
        flETH.approve(address(poolSwap), type(uint).max);
        _swap(SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // It should initialize the position, just below the current price
        (initialized,,, spent, burned) = buyBackAndBurnFlay.positionInfo();
        assertTrue(initialized);
        assertEq(spent, 2.5 ether);
        assertEq(burned, 0);
    }

    function test_Can_SetEthThreshold(
        uint _threshold
    ) public {
        vm.expectEmit();
        emit IBuyBackAndBurnFlay.ThresholdUpdated(_threshold);

        buyBackAndBurnFlay.setEthThreshold(_threshold);

        assertEq(buyBackAndBurnFlay.ethThreshold(), _threshold);
    }

    function test_Cannot_SetEthThreshold_IfNotOwner(
        address _caller,
        uint _threshold
    ) public {
        vm.assume(_caller != address(this));

        vm.startPrank(_caller);

        vm.expectRevert(UNAUTHORIZED);
        buyBackAndBurnFlay.setEthThreshold(_threshold);

        vm.stopPrank();
    }

    function test_Can_SetPoolKey() public {
        vm.expectEmit();
        emit IBuyBackAndBurnFlay.PoolKeyUpdated(poolKey);

        buyBackAndBurnFlay.setPoolKey(poolKey);
    }

    function test_Cannot_SetPoolKey_IfNotOwner(
        address _caller
    ) public {
        vm.assume(_caller != address(this));

        vm.startPrank(_caller);

        vm.expectRevert(UNAUTHORIZED);
        buyBackAndBurnFlay.setPoolKey(poolKey);

        vm.stopPrank();
    }

    // Helpers

    function _swap(
        SwapParams memory swapParams
    ) internal returns (BalanceDelta delta) {
        delta = poolSwap.swap(poolKey, swapParams);
    }

    modifier poolHasLiquidity() {
        // Ensure that FairLaunch period has ended for the token
        vm.warp(block.timestamp + 1 days);

        memecoin.mint(alice, 100_000_000 ether);
        deal(address(flETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        flETH.approve(address(poolModifyPosition), type(uint).max);

        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1000 ether,
                salt: ''
            }),
            ''
        );
        vm.stopPrank();

        deal(address(flETH), alice, 0);

        _;
    }
}
