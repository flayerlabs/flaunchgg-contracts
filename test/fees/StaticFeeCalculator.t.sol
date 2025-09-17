// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {StaticFeeCalculator} from '@flaunch/fees/StaticFeeCalculator.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract StaticFeeCalculatorTest is FlaunchTest {

    StaticFeeCalculator feeCalculator;

    PoolKey internal _poolKey;

    function setUp() public {
        _deployPlatform();

        feeCalculator = new StaticFeeCalculator(address(flETH), address(customFeeManagerRegistry));

        address memecoin = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: supplyShare(50),
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 100_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Set up an example {PoolKey}
        _poolKey = positionManager.poolKey(memecoin);
    }

    function test_CanDetermineSwapFee(uint _swapAmount, uint16 _baseFee) public view {
        assertEq(feeCalculator.determineSwapFee(_poolKey, _getSwapParams(int(_swapAmount)), _baseFee), _baseFee);
    }

    function test_CanTrackSwap() public {
        vm.startPrank(address(positionManager), address(positionManager));
        _trackSwap();
        vm.stopPrank();
    }

    function _trackSwap() internal {
        feeCalculator.trackSwap(
            address(1),
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 3 ether,
                sqrtPriceLimitX96: uint160(int160(TickMath.minUsableTick(_poolKey.tickSpacing)))
            }),
            toBalanceDelta(0, 0),
            ''
        );
    }

}
