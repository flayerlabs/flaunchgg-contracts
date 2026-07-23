// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {INotifier} from '@flaunch-interfaces/INotifier.sol';
import {Notifier} from '@flaunch/hooks/Notifier.sol';

import {SubscriberMock} from '../mocks/SubscriberMock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract NotifierTest is FlaunchTest {
    SubscriberMock subscriber;

    Notifier notifier;
    PoolId internal constant POOL_ID = PoolId.wrap('PoolId');

    function setUp() public {
        _deployPlatform();

        notifier = positionManager.notifier();

        // Deploy our subscriber mock
        subscriber = new SubscriberMock(address(notifier));
    }

    function test_CanSubscribe() public {
        // Test successful registration of a new subscriber
        vm.expectEmit();
        emit INotifier.Subscription(address(subscriber));

        notifier.subscribe(address(subscriber), abi.encode(true));
    }

    function test_CanPreventBrokenSubscribe() public {
        vm.expectRevert(INotifier.SubscriptionReverted.selector);
        notifier.subscribe(address(subscriber), abi.encode(false));
    }

    function test_CanSubscribeDuplicateAddress() public {
        // Register the subscriber once
        notifier.subscribe(address(subscriber), abi.encode(true));

        // Attempt to register the same subscriber again. This will not revert but it won't
        // actually add them to the set.
        notifier.subscribe(address(subscriber), abi.encode(true));
    }

    function test_CanUnsubscribeAddress() public {
        notifier.subscribe(address(subscriber), abi.encode(true));

        vm.expectEmit();
        emit SubscriberMock.Unubscribe();

        notifier.unsubscribe(address(subscriber));
    }

    function test_CanUnsubscribeUnknownAddress() public {
        notifier.unsubscribe(address(subscriber));
    }

    function test_CanNotifySubscribers() public {
        // Register multiple subscribers and notify them
        SubscriberMock subscriber2 = new SubscriberMock(address(notifier));

        notifier.subscribe(address(subscriber), abi.encode(true));
        notifier.subscribe(address(subscriber2), abi.encode(true));

        vm.expectEmit(true, true, false, false, address(subscriber));
        emit SubscriberMock.Notify(POOL_ID);

        vm.expectEmit(true, true, false, false, address(subscriber2));
        emit SubscriberMock.Notify(POOL_ID);

        // Trigger notification (this is mocked, normally required swap / liquidity modification)
        positionManager.emitPoolStateUpdate(POOL_ID);
    }

    function test_NotifyWithNoSubscribersRegistered() public {
        // Ensure there are no errors and no events were emitted
        // (use logs or specific assertions here if available)
        positionManager.emitPoolStateUpdate(POOL_ID);
    }
}
