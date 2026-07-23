// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Does nothing.
 *
 * @dev This is just used for testing purposes.
 */
contract BlankAction is ITreasuryAction {
    function execute(
        PoolKey memory _poolKey,
        bytes memory
    ) external override {
        emit ActionExecuted(_poolKey, 0, 0);
    }
}
