// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface IBuyBackAndBurnFlay {
    event BurnBabyBurn(uint _flayBurned);
    event EthBalanceUpdated(uint _ethBalance);
    event PoolKeyUpdated(PoolKey _poolKey);
    event ThresholdUpdated(uint _ethThreshold);

    struct PositionInfo {
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint spent;
        uint burned;
    }

    function ethThreshold() external view returns (uint);
    function positionInfo() external view returns (bool initialized, int24 tickLower, int24 tickUpper, uint spent, uint burned);
    function subscribe(
        bytes memory _data
    ) external returns (bool);
    function notify(
        PoolId _poolId,
        bytes4 _key,
        bytes calldata _data
    ) external;
    function setEthThreshold(
        uint _ethThreshold
    ) external;
    function setPoolKey(
        PoolKey memory _poolKey
    ) external;
}
