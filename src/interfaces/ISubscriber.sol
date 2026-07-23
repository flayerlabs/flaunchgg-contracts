// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

/**
 * Interface that a Subscriber contract should implement to receive updates from the Flaunch
 * {Notifier}.
 */
interface ISubscriber {
    function subscribe(
        bytes memory data
    ) external returns (bool);

    function unsubscribe() external;

    function notify(
        PoolId _poolId,
        bytes4 _key,
        bytes calldata _data
    ) external;
}
