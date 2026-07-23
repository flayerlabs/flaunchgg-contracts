// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {ISubscriber} from '@flaunch-interfaces/ISubscriber.sol';

/**
 * Empty Subscriber contract that can be extended from.
 */
contract SubscriberMock is ISubscriber {
    event Subscribe(bytes _data);
    event Unubscribe();
    event Notify(PoolId _poolId);

    /// The Flaunch {Notifier} contract that will make approved calls
    address public immutable notifier;

    /**
     * Sets our {PositionManager} so that we can lock down all the calls.
     */
    constructor(
        address _notifier
    ) {
        notifier = _notifier;
    }

    /**
     * Called when the contract is subscribed to the PositionManager.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(
        bytes calldata _data
    ) public virtual isNotifier returns (bool _success) {
        (_success) = abi.decode(_data, (bool));
        emit Subscribe(_data);
    }

    /**
     * Called when the contract is unsubscribed to the PositionManager.
     */
    function unsubscribe() public virtual isNotifier {
        emit Unubscribe();
    }

    /**
     * Called when an action has been performed against a pool.
     */
    function notify(
        PoolId _poolId,
        bytes4,
        bytes calldata
    ) public virtual isNotifier {
        emit Notify(_poolId);
    }

    /**
     * Ensure that the caller is the {Notifier}.
     */
    modifier isNotifier() {
        require(msg.sender == notifier);
        _;
    }
}
