// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

interface INotifier {
    error SubscriptionReverted();
    error TooManySubscribers();

    event Subscription(address _subscriber);
    event Unsubscription(address _subscriber);
    event NotifyFailed(address _subscriber, bytes _reason);

    function subscribe(
        address _subscriber,
        bytes calldata _data
    ) external;
    function unsubscribe(
        address _subscriber
    ) external;
    function notifySubscribers(
        PoolId _poolId,
        bytes4 _key,
        bytes calldata _data
    ) external;
}
