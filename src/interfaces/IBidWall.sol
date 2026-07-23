// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface IBidWall {
    error CallerIsNotCreator();
    error NotPositionManager();

    /// Emitted when the BidWall is first initialised with ETH
    event BidWallInitialized(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when a BidWall receives a deposit
    event BidWallDeposit(PoolId indexed _poolId, uint _added, uint _pending);

    /// Emitted when the BidWall is repositioned under an updated tick, or with additional ETH
    event BidWallRepositioned(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when non-ETH tokens received are transferrer to the memecoin treasury
    event BidWallRewardsTransferred(PoolId indexed _poolId, address _recipient, uint _tokens);

    /// Emitted when the BidWall is closed
    event BidWallClosed(PoolId indexed _poolId, address _recipient, uint _eth);

    /// Emitted when the BidWall is disabled or enabled
    event BidWallDisabledStateUpdated(PoolId indexed _poolId, bool _disabled);

    /// Emitted when the `_swapFeeThreshold` is updated
    event FixedSwapFeeThresholdUpdated(uint _newSwapFeeThreshold);

    /// Emitted when the `staleTimeWindow` is updated
    event StaleTimeWindowUpdated(uint _staleTimeWindow);

    /**
     * Stores the BidWall information for a specific pool.
     *
     * @member disabled If the BidWall is disabled for the pool
     * @member initialized If the BidWall has been initialized
     * @member tickLower The current lower tick of the BidWall
     * @member tickUpper The current upper tick of the BidWall
     * @member pendingETHFees The amount of ETH fees waiting to be put into the BidWall until threshold is crossed
     * @member cumulativeSwapFees The total amount of swap fees accumulated for the pool
     */
    struct PoolInfo {
        bool disabled;
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint pendingETHFees;
        uint cumulativeSwapFees;
    }

    function poolInfo(
        PoolId _poolId
    )
        external
        view
        returns (bool disabled, bool initialized, int24 tickLower, int24 tickUpper, uint pendingETHFees, uint cumulativeSwapFees);

    function lastPoolTransaction(
        PoolId _poolId
    ) external view returns (uint);

    function staleTimeWindow() external view returns (uint);

    function isBidWallEnabled(
        PoolId _poolId
    ) external view returns (bool);

    function deposit(
        PoolKey memory _poolKey,
        uint _ethSwapAmount,
        int24 _currentTick,
        bool _nativeIsZero
    ) external;

    function checkStalePosition(
        PoolKey memory _poolKey,
        int24 _currentTick,
        bool _nativeIsZero
    ) external;

    function setDisabledState(
        PoolKey memory _key,
        bool _disable
    ) external;

    function closeBidWall(
        PoolKey memory _key
    ) external;

    function position(
        PoolId _poolId
    ) external view returns (uint amount0_, uint amount1_, uint pendingEth_);

    function setSwapFeeThreshold(
        uint swapFeeThreshold
    ) external;

    function setStaleTimeWindow(
        uint _staleTimeWindow
    ) external;
}
