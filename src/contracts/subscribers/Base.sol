// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {ISubscriber} from '@flaunch-interfaces/ISubscriber.sol';

/**
 * Empty Subscriber contract that can be extended from.
 */
abstract contract BaseSubscriber is ISubscriber {
    error InvalidNotifier(address _sender, address _validNotifier);

    /// The Flaunch {Notifier} contract that will make approved calls
    address public immutable notifier;

    /**
     * Sets our {Notifier} so that we can lock down all the calls.
     */
    constructor(
        address _notifier
    ) {
        notifier = _notifier;
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(
        bytes memory /* _data */
    ) public virtual onlyNotifier returns (bool) {
        return false;
    }

    /**
     * Called when the contract is unsubscribed to the Notifier.
     */
    function unsubscribe() public virtual onlyNotifier {
        // ..
    }

    /**
     * Called when an action has been performed against a pool.
     */
    function notify(
        PoolId,
        /* _poolId */
        bytes4,
        /* _key */
        bytes calldata /* _data */
    ) public virtual onlyNotifier {
        // ..
    }

    /**
     * Ensure that the caller is the {Notifier}.
     */
    modifier onlyNotifier() {
        if (msg.sender != notifier) {
            revert InvalidNotifier(msg.sender, notifier);
        }

        _;
    }
}
