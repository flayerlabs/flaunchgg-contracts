// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {BidWall} from '@flaunch/bidwall/BidWall.sol';

/**
 * Applies a version of the BidWall that uses a fixed swap fee threshold.
 */
contract BidWallMock is BidWall {
    constructor(
        address _nativeToken,
        address _poolManager,
        address _protocolOwner
    ) BidWall(_nativeToken, _poolManager, _protocolOwner) {}

    function setPoolInfo(
        PoolId _poolId,
        PoolInfo memory _poolInfo
    ) public {
        poolInfo[_poolId] = _poolInfo;
    }

    function setSwapFeeThresholdMock(
        uint swapFeeThreshold
    ) public {
        _swapFeeThreshold = swapFeeThreshold;
        emit FixedSwapFeeThresholdUpdated(_swapFeeThreshold);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return false;
    }
}
