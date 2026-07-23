// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from 'forge-std/Vm.sol';

import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {Notifier} from '@flaunch/hooks/Notifier.sol';

import {SubscriberMock} from '../mocks/SubscriberMock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

/**
 * A subscriber whose `notify` always reverts, modelling a corrupted/misbehaving subscriber.
 */
contract RevertingSubscriberMock is SubscriberMock {
    error SubscriberBroken();

    constructor(
        address _notifier
    ) SubscriberMock(_notifier) {}

    function notify(
        PoolId,
        bytes4,
        bytes calldata
    ) public pure override {
        revert SubscriberBroken();
    }
}

/**
 * Regression coverage for audit finding F-15.
 *
 * `Notifier.notifySubscribers` previously looped over `ISubscriber.notify` with no try/catch, so a
 * single reverting subscriber bricked every swap/launch/liquidity op that routed through it. Each
 * notification must now be wrapped so a failing subscriber emits `NotifyFailed` and never blocks
 * the protocol operation.
 */
contract F15RevertingSubscriberTest is FlaunchTest {
    RevertingSubscriberMock internal reverting;
    Notifier internal notifier;

    function setUp() public {
        _deployPlatform();

        notifier = positionManager.notifier();
        reverting = new RevertingSubscriberMock(address(notifier));
    }

    function test_F15_RevertingSubscriberDoesNotBrickSwap() public {
        // Flaunch a memecoin
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        PoolKey memory poolKey = positionManager.poolKey(memecoin);

        // Fund + approve for the swap, and prime the PoolManager with flETH
        flETH.deposit{value: 100 ether}();
        flETH.approve(address(poolSwap), type(uint).max);
        flETH.transfer(address(poolManager), 50 ether);

        // Subscribe the reverting subscriber (onlyOwner; this test is the Notifier owner)
        notifier.subscribe(address(reverting), abi.encode(true));

        // A swap triggers `_afterSwap` -> `notifySubscribers`. The reverting subscriber must not
        // brick the swap: capture logs, confirm the swap did not revert and that a `NotifyFailed`
        // event was emitted for the broken subscriber.
        vm.recordLogs();
        poolSwap.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 notifyFailedTopic = keccak256('NotifyFailed(address,bytes)');
        bool found;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].emitter == address(notifier) && logs[i].topics.length != 0 && logs[i].topics[0] == notifyFailedTopic) {
                (address sub, bytes memory reason) = abi.decode(logs[i].data, (address, bytes));
                if (sub == address(reverting)) {
                    assertEq(reason, abi.encodeWithSelector(RevertingSubscriberMock.SubscriberBroken.selector), 'unexpected revert reason');
                    found = true;
                }
            }
        }

        assertTrue(found, 'NotifyFailed not emitted for the reverting subscriber');
    }
}
