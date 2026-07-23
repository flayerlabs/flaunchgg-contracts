// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface IMemecoinTreasury {
    error ActionNotApproved();
    error Unauthorized();

    event ActionExecuted(address indexed _action, PoolKey _poolKey, bytes _data);

    function initialize(
        address payable _positionManager,
        address _actionManager,
        address _nativeToken,
        PoolKey memory _poolKey
    ) external;
    function executeAction(
        address _action,
        bytes memory _data
    ) external;
    function claimFees() external;
}
