// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {StaticFeeCalculator} from '@flaunch/fees/StaticFeeCalculator.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract StaticFeeCalculatorTest is FlaunchTest {
    address internal constant POSITION_MANAGER = address(10);

    StaticFeeCalculator feeCalculator;

    PoolKey internal _poolKey;

    function setUp() public {
        feeCalculator = new StaticFeeCalculator();

        // Set up an example {PoolKey}
        _poolKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(POSITION_MANAGER)
        });
    }

    function test_CanDetermineSwapFee(
        uint _swapAmount,
        uint16 _baseFee
    ) public view {
        assertEq(feeCalculator.determineSwapFee(_poolKey, _getSwapParams(int(_swapAmount)), _baseFee), _baseFee);
    }

    function test_CanTrackSwap() public {
        _trackSwap();
    }

    function _trackSwap() internal {
        feeCalculator.trackSwap(
            address(1),
            _poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: 3 ether, sqrtPriceLimitX96: uint160(int160(TickMath.minUsableTick(_poolKey.tickSpacing)))
            }),
            toBalanceDelta(0, 0),
            ''
        );
    }
}
