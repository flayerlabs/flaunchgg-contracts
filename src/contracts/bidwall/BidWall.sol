// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';


/**
 * This hook allows us to create a single sided liquidity position (Plunge Protection) that is
 * placed 1 tick below spot price, using the ETH fees accumulated.
 * 这个钩子允许我们创建一个单边流动性位置（Plunge Protection），放置在当前价格下方1个tick的位置，使用累积的ETH费用。
 * After each deposit into the BidWall the position is rebalanced to ensure it remains 1 tick
 * below spot. This spot will be determined by the tick value before the triggering swap.
 * 每次存入BidWall时，位置都会重新平衡，以确保它保持在当前价格下方1个tick。这个当前价格将由触发交换前的tick值确定。
 */
contract BidWall is AccessControl, Ownable {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickFinder for int24;
    using MemecoinFinder for PoolKey;

    error CallerIsNotCreator();
    error NotPositionManager();

    /// Emitted when the BidWall is first initialised with ETH 当BidWall第一次初始化时发出事件
    event BidWallInitialized(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when a BidWall receives a deposit 当BidWall收到存款时发出事件
    event BidWallDeposit(PoolId indexed _poolId, uint _added, uint _pending);

    /// Emitted when the BidWall is repositioned under an updated tick, or with additional ETH 当BidWall重新定位到更新的tick，或使用额外的ETH时发出事件
    event BidWallRepositioned(PoolId indexed _poolId, uint _eth, int24 _tickLower, int24 _tickUpper);

    /// Emitted when non-ETH tokens received are transferrer to the memecoin treasury 当非ETH代币收到时，被转移到memecoin Treasury时发出事件
    event BidWallRewardsTransferred(PoolId indexed _poolId, address _recipient, uint _tokens);

    /// Emitted when the BidWall is closed 当BidWall关闭时发出事件
    event BidWallClosed(PoolId indexed _poolId, address _recipient, uint _eth);

    /// Emitted when the BidWall is disabled or enabled 当BidWall被禁用或启用时发出事件
    event BidWallDisabledStateUpdated(PoolId indexed _poolId, bool _disabled);

    /// Emitted when the `_swapFeeThreshold` is updated 当`_swapFeeThreshold`更新时发出事件
    event FixedSwapFeeThresholdUpdated(uint _newSwapFeeThreshold);

    /// Emitted when the `staleTimeWindow` is updated 当`staleTimeWindow`更新时发出事件
    event StaleTimeWindowUpdated(uint _staleTimeWindow);

    /**
     * Stores the BidWall information for a specific pool. 存储BidWall信息用于特定池。
     *
     * @member disabled If the BidWall is disabled for the pool 如果BidWall为池禁用
     * @member initialized If the BidWall has been initialized 如果BidWall已初始化
     * @member tickLower The current lower tick of the BidWall 当前BidWall的较低tick
     * @member tickUpper The current upper tick of the BidWall 当前BidWall的较高tick
     * @member pendingETHFees The amount of ETH fees waiting to be put into the BidWall until threshold is crossed 等待存入BidWall的ETH费用，直到阈值被跨越
     * @member cumulativeSwapFees The total amount of swap fees accumulated for the pool 池中累积的交换费用总额
     */
    struct PoolInfo {
        bool disabled;
        bool initialized;
        int24 tickLower;
        int24 tickUpper;
        uint pendingETHFees;
        uint cumulativeSwapFees;
    }

    /// Our Uniswap V4 {PoolManager} contract 我们的Uniswap V4 {PoolManager}合同
    IPoolManager public immutable poolManager;

    /// The native token used in the Flaunch protocol 在Flaunch协议中使用的原生代币
    address public immutable nativeToken;

    /// Timeout period to make a BidWall stale based on last transaction time 基于最后交易时间的BidWall过期时间
    uint public staleTimeWindow = 7 days;

    /// Our fixed swap fee threshold 我们的固定交换费用阈值
    uint internal _swapFeeThreshold;

    /// Maps our poolId to the `PoolInfo` struct for bidWall data 将我们的poolId映射到`PoolInfo`结构体用于BidWall数据
    mapping (PoolId _poolId => PoolInfo _poolInfo) public poolInfo;

    /// Maps the last transaction time for a pool BidWall 将池的BidWall的最后交易时间映射到时间戳
    mapping (PoolId _poolId => uint _timestamp) public lastPoolTransaction;

    /**
     * Set up our PoolManager and native ETH token. 设置我们的PoolManager和原生ETH代币。
     * 
     * @param _nativeToken The ETH token being used in the {PositionManager} 在{PositionManager}中使用的ETH代币
     * @param _poolManager The Uniswap V4 {PoolManager} Uniswap V4 {PoolManager}
     * @param _protocolOwner The address of the protocol owner 协议所有者的地址
     */
    constructor (address _nativeToken, address _poolManager, address _protocolOwner) {
        nativeToken = _nativeToken;
        poolManager = IPoolManager(_poolManager);

        // Set our initial swapFeeThreshold and emit an update for the amount 设置我们的初始交换费用阈值并发出更新
        _swapFeeThreshold = 0.1 ether;
        emit FixedSwapFeeThresholdUpdated(0.1 ether);

        // Emit our initial `staleTimeWindow` update 发出我们的初始`staleTimeWindow`更新
        emit StaleTimeWindowUpdated(staleTimeWindow);

        // Set our caller to have the default admin of protocol roles 设置我们的调用者为协议角色的默认管理员
        _grantRole(DEFAULT_ADMIN_ROLE, _protocolOwner);

        _initializeOwner(_protocolOwner);
    }

    /**
     * Helper function that checks if a pool's BidWall is enabled or disabled.
     * 辅助函数，检查池的BidWall是否启用或禁用。
     * @param _poolId The pool ID to check
     *
     * @return bool Set to `true` if the hook is enabled, `false` if it is disabled
     */
    function isBidWallEnabled(PoolId _poolId) public view returns (bool) {
        return !poolInfo[_poolId].disabled;
    }

    /**
     * Attributes swap fees to the BidWall and calculates if it needs to rebalance
     * the current position.
     * 将交换费用归属于BidWall，并计算是否需要重新平衡当前位置。
     * @dev The calling contract should have already checked if this hook is active
     * and ready to receive the swap fees.
     * 调用合约应已检查此钩子是否活动并准备好接收交换费用。
     * @param _poolKey The PoolKey to modify the BidWall of
     * @param _ethSwapAmount The amount of ETH swap fees added to BidWall
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is `currency0`
     */
    function deposit(
        PoolKey memory _poolKey,
        uint _ethSwapAmount,
        int24 _currentTick,
        bool _nativeIsZero
    ) public onlyPositionManager {
        // If we have no fees to swap, then exit early 如果没有要交换的费用，则提前退出
        if (_ethSwapAmount == 0) return;

        // Increase our cumulative and pending fees 增加我们的累积和待处理费用
        PoolId poolId = _poolKey.toId();
        PoolInfo storage _poolInfo = poolInfo[poolId];
        _poolInfo.cumulativeSwapFees += _ethSwapAmount;
        _poolInfo.pendingETHFees += _ethSwapAmount;

        // Update the last transaction timestamp 更新最后交易时间戳
        lastPoolTransaction[poolId] = block.timestamp;

        // Send an event to notify that BidWall has received funds 发送事件通知BidWall已收到资金
        emit BidWallDeposit(poolId, _ethSwapAmount, _poolInfo.pendingETHFees);

        // If we haven't yet crossed a threshold, then we just increase the amount of
        // pending fees to calculate against next time. 如果没有跨越阈值，则仅增加待处理费用以计算下次。
        if (_poolInfo.pendingETHFees < _getSwapFeeThreshold(_poolInfo.cumulativeSwapFees)) {
            return;
        }

        // Modify our position to rebalance the liquidity 修改我们的位置以重新平衡流动性
        _reposition(_poolKey, _poolInfo, _currentTick, _nativeIsZero);
    }

    /**
     * If there has been no transaction in the BidWall for a period of time, then we reposition
     * the liquidity early ahead of the threshold being met. This check takes place in the
     * `beforeSwap` hook so that the provided liquidity is present before the swap.
     * 如果BidWall在一段时间内没有交易，则提前重新定位流动性。这个检查发生在`beforeSwap`钩子中，以便在交换之前提供流动性。
     * @param _poolKey The PoolKey to modify the BidWall of
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is `currency0`
     */
    function checkStalePosition(
        PoolKey memory _poolKey,
        int24 _currentTick,
        bool _nativeIsZero
    ) external onlyPositionManager {
        // If our pool has not fallen stale, then exit early 如果池还没有变得陈旧，则提前退出
        PoolId poolId = _poolKey.toId();
        if (lastPoolTransaction[poolId] + staleTimeWindow > block.timestamp) {
            return;
        }

        // If the BidWall has no pending fees, then we will have nothing to extract
        // early, so we don't need to process our reposition. 如果BidWall没有待处理费用，那么我们早期就没有东西可以提取，所以我们不需要处理重新定位。
        PoolInfo storage _poolInfo = poolInfo[poolId];
        if (_poolInfo.pendingETHFees == 0) {
            return;
        }

        // Otherwise, if it is stale then we can exit the liquidity early 否则，如果它变得陈旧，那么我们可以提前退出流动性
        _reposition(_poolKey, _poolInfo, _currentTick, _nativeIsZero);
    }

    /**
     * Repositions our BidWall liquidity, first extracting the existing position and then creating
     * a new position. 重新定位我们的BidWall流动性，首先提取现有位置，然后创建一个新位置。
     *
     * @param _poolKey The PoolKey to modify the BidWall of
     * @param _poolInfo BidWall information for a specific pool
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is `currency0`
     */
    function _reposition(PoolKey memory _poolKey, PoolInfo storage _poolInfo, int24 _currentTick, bool _nativeIsZero) internal {
        // Reset pending ETH token fees as we will be processing a bidwall initialization
        // or a rebalance.
        uint totalFees = _poolInfo.pendingETHFees;
        _poolInfo.pendingETHFees = 0;

        uint ethWithdrawn;
        uint memecoinWithdrawn;

        // Check if the BidWall has been initialized before, then we have a position
        if (_poolInfo.initialized) {
            // Remove tokens from our current position
            (ethWithdrawn, memecoinWithdrawn) = _removeLiquidity({
                _key: _poolKey,
                _nativeIsZero: _nativeIsZero,
                _tickLower: _poolInfo.tickLower,
                _tickUpper: _poolInfo.tickUpper
            });

            // Send the received ETH to the {PositionManager}, as that will be supplying the ETH
            // tokens to create the new position.
            if (ethWithdrawn != 0) {
                IERC20(nativeToken).transfer(msg.sender, ethWithdrawn);
            }
        } else {
            // If this is the first time we are adding liquidity, then we can set our
            // pool initialized flag to true.
            _poolInfo.initialized = true;
        }

        /**
         * The `_currentTick` is calculated from the `_beforeSwapTick`, which means that it could be
         * that the actual swap has impacted the tick of the pool. This will affect our liquidity
         * modification in one of two ways:
         *
         *   1. The tick has moved FOR the native token, meaning that we will be creating our position to
         *      give a lower native token value. This is absolutely fine and is expected so as to not give
         *      an overly generous price when the BidWall is triggered.
         *   2. The tick has moved AGAINST the native token, meaning that we will be creating our position
         *      to give a higher native token value. This means that liquidity calculations called within
         *      the `_addETHLiquidity` will actually result in requiring both native _and_ memecoin tokens
         *      to be settled. If this is the case then we instead need to use the `slot0` tick rather than
         *      the beforeSwap tick value provided in `_currentTick`.
         *
         * This is the final, and only, place that `_currentTick` is referenced, so we can safely overwrite
         * the value if required.
         */

        PoolId poolId = _poolKey.toId();
        (, int24 slot0Tick,,) = poolManager.getSlot0(poolId);
        if (_nativeIsZero == slot0Tick > _currentTick) {
            _currentTick = slot0Tick;
        }

        // Create our liquidity position; including any tokens withdrawn from our previous position if
        // set, as well as the additional swap fees.
        _addETHLiquidity({
            _key: _poolKey,
            _nativeIsZero: _nativeIsZero,
            _currentTick: _currentTick,
            _ethAmount: ethWithdrawn + totalFees
        });

        // If we have memecoins available, then we transfer those to the treasury
        if (memecoinWithdrawn != 0) {
            // Find our non-ETH token and the {TokenTreasury} attached to it
            address memecoin = address(_poolKey.memecoin(nativeToken));
            address memecoinTreasury = _getMemecoinTreasury(_poolKey, memecoin);

            // Transfer the tokens to the memecoin treasury
            IERC20(memecoin).transfer(memecoinTreasury, memecoinWithdrawn);
            emit BidWallRewardsTransferred(poolId, memecoinTreasury, memecoinWithdrawn);
        }

        emit BidWallRepositioned(poolId, ethWithdrawn + totalFees, _poolInfo.tickLower, _poolInfo.tickUpper);
    }

    /**
     * Retrieves the treasury address for a given memecoin.
     *
     * @param _poolKey The {PoolKey} that we are finding the treasury for
     * @param _memecoin The address of the memecoin
     *
     * @return memecoinTreasury_ The treasury address for the memecoin
     */
    function _getMemecoinTreasury(PoolKey memory _poolKey, address _memecoin) internal view virtual returns (address memecoinTreasury_) {
        memecoinTreasury_ = IMemecoin(_memecoin).treasury();
    }

    /**
     * Retrieves the creator address for a given memecoin.
     *
     * @param _poolKey The {PoolKey} that we are finding the creator for
     * @param _memecoin The address of the memecoin
     *
     * @return creator_ The creator address for the memecoin
     */
    function _getMemecoinCreator(PoolKey memory _poolKey, address _memecoin) internal view virtual returns (address creator_) {
        creator_ = IMemecoin(_memecoin).creator();
    }

    /**
     * Allows the BidWall to be enabled or disabled for the {PoolKey}.
     *
     * If disabled, future swap fees will be transferred directly to the respective
     * {MemecoinTreasury} address instead of the BidWall.
     *
     * @dev This can only be called by the creator of the memecoin.
     *
     * @param _key The PoolKey that is being updated
     * @param _disable If the BidWall is being disabled (true) or enabled (false)
     */
    function setDisabledState(PoolKey memory _key, bool _disable) external {
        // Ensure that the caller is the pool creator
        if (msg.sender != _getMemecoinCreator(_key, address(_key.memecoin(nativeToken)))) revert CallerIsNotCreator();

        // We only need to process the following logic if anything is changing
        PoolInfo storage _poolInfo = poolInfo[_key.toId()];
        if (_disable == _poolInfo.disabled) return;

        // If we are disabling our BidWall, then we want to also remove the current liquidity. We
        // need to send this through the {PositionManager} so that it can open a {PoolManager} lock.
        if (_disable) {
            PositionManager(payable(address(_key.hooks))).closeBidWall(_key);
        }

        // Update our disabled flag
        _poolInfo.disabled = _disable;

        // Emit our event to flag the BidWall disabled state update
        emit BidWallDisabledStateUpdated(_key.toId(), _disable);
    }

    /**
     * Allows the memecoin creator to close the BidWall and distribute any fees held in the BidWall
     * to the treasury address.
     *
     * This call will have been routed in the following way:
     * ```
     * BidWall.disable -> PositionManager.closeBidWall -> PositionManager.unlockCallback -> BidWall.closeBidwall
     * ```
     *
     * @param _key The PoolKey that we are closing the BidWall of
     */
    function closeBidWall(PoolKey memory _key) external onlyPositionManager {
        // Unpack information required for our call
        bool nativeIsZero = nativeToken == Currency.unwrap(_key.currency0);

        PoolId poolId = _key.toId();
        PoolInfo storage _poolInfo = poolInfo[poolId];

        uint ethWithdrawn;
        uint memecoinWithdrawn;

        // If the pool has not yet been initialized, then there will be no liquidity to remove
        if (_poolInfo.initialized) {
            // Remove all liquidity from the BidWall
            (ethWithdrawn, memecoinWithdrawn) = _removeLiquidity({
                _key: _key,
                _nativeIsZero: nativeIsZero,
                _tickLower: _poolInfo.tickLower,
                _tickUpper: _poolInfo.tickUpper
            });

            // Set our pool back to being uninitialized
            _poolInfo.initialized = false;
        }

        // Reset pending ETH fees for the pool. We also reset our `cumulativeSwapFees` as this is
        // used to determine our threshold hits.
        uint pendingETHFees = _poolInfo.pendingETHFees;
        _poolInfo.pendingETHFees = 0;
        _poolInfo.cumulativeSwapFees = 0;

        // Unwrap the non-native token and find the treasury address
        address memecoin = address(_key.memecoin(nativeToken));
        address memecoinTreasury = _getMemecoinTreasury(_key, memecoin);

        // Pending ETH fees are stored in the {PositionManager}. So if we have a value there, then we
        // will need to transfer this from the {PositionManager}, rather than this contract.
        if (pendingETHFees != 0) {
            IERC20(nativeToken).transferFrom(msg.sender, memecoinTreasury, pendingETHFees);
        }

        // Transfer ETH withdrawn from the legacy position to the governance contract. We Avoid using
        // safe transfer as this could brick calls if a malicious governance was set by the token.
        if (ethWithdrawn != 0) {
            IERC20(nativeToken).transfer(memecoinTreasury, ethWithdrawn);
        }

        // Transfer the flTokens withdrawn from the legacy position to the governance contract
        if (memecoinWithdrawn != 0) {
            IERC20(memecoin).transfer(memecoinTreasury, memecoinWithdrawn);
            emit BidWallRewardsTransferred(poolId, memecoinTreasury, memecoinWithdrawn);
        }

        emit BidWallClosed(poolId, memecoinTreasury, ethWithdrawn + pendingETHFees);
    }

    /**
     * Retrieves the current position held by the BidWall.
     *
     * @param _poolId The `PoolId` to check the {BidWall} position of
     *
     * @return amount0_ The {BidWall} token0 position
     * @return amount1_ The {BidWall} token1 position
     * @return pendingEth_ The amount of ETH pending to be depositted into the {BidWall}
     */
    function position(PoolId _poolId) public view returns (uint amount0_, uint amount1_, uint pendingEth_) {
        // Get the BidWall tick range from our PoolInfo
        PoolInfo memory _poolInfo = poolInfo[_poolId];

        // If our pool is not initialized, then we don't have a position to query and we will
        // only have the pending fees to return
        if (!_poolInfo.initialized) {
            return (0, 0, _poolInfo.pendingETHFees);
        }

        // Retrieve the total liquidity of the pool
        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: _poolId,
            owner: address(this),
            tickLower: _poolInfo.tickLower,
            tickUpper: _poolInfo.tickUpper,
            salt: 'bidwall'
        });

        // Get the current slot of the pool and find the amounts against the liquidity
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        (amount0_, amount1_) = LiquidityAmounts.getAmountsForLiquidity({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_poolInfo.tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_poolInfo.tickUpper),
            liquidity: liquidity
        });

        // Map our pending fees to our response
        pendingEth_ = _poolInfo.pendingETHFees;
    }

    /**
     * Allows the threshold for the swap fee to be updated.
     *
     * @param swapFeeThreshold The new threshold to set
     */
    function setSwapFeeThreshold(uint swapFeeThreshold) external onlyOwner {
        _swapFeeThreshold = swapFeeThreshold;
        emit FixedSwapFeeThresholdUpdated(_swapFeeThreshold);
    }

    /**
     * Allows the threshold for a BidWall to be deemed stale to be updated.
     *
     * @param _staleTimeWindow The new stale time window to set
     */
    function setStaleTimeWindow(uint _staleTimeWindow) external onlyOwner {
        staleTimeWindow = _staleTimeWindow;
        emit StaleTimeWindowUpdated(_staleTimeWindow);
    }

    /**
     * Adds liquidity to our BidWall position. We calculate the tick to be adjacent to the current
     * tick of the pool into a single tick spaced range.
     *
     * @param _key The {PoolKey} that is being modified
     * @param _nativeIsZero If our native token is `currency0`
     * @param _currentTick The current tick for the pool
     * @param _ethAmount The amount of native token we are adding to the BidWall
     */
    function _addETHLiquidity(PoolKey memory _key, bool _nativeIsZero, int24 _currentTick, uint _ethAmount) internal {
        // If we have no ETH to process, then we cannot create a position
        if (_ethAmount == 0) {
            return;
        }

        // Determine a base tick just outside of the current tick
        int24 baseTick = _nativeIsZero ? _currentTick + 1 : _currentTick - 1;

        /**
         * Calculate the tick range for the BidWall.
         *
         *                   tick ( lower | upper )
         * When the tick is  6931 (  6960 |  7020 )
         * When the tick is -6932 ( -7020 | -6960 )
         */

        int24 newTickLower;
        int24 newTickUpper;
        uint128 liquidityDelta;

        if (_nativeIsZero) {
            newTickLower = baseTick.validTick(false);
            newTickUpper = newTickLower + TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount0: _ethAmount
            });
        } else {
            newTickUpper = baseTick.validTick(true);
            newTickLower = newTickUpper - TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount1: _ethAmount
            });
        }

        // Modify the liquidity to add our position
        _modifyAndSettleLiquidity({
            _poolKey: _key,
            _tickLower: newTickLower,
            _tickUpper: newTickUpper,
            _liquidityDelta: int128(liquidityDelta),
            _sender: address(_key.hooks)
        });

        // Update the BidWall position tick range
        PoolInfo storage _poolInfo = poolInfo[_key.toId()];
        _poolInfo.tickLower = newTickLower;
        _poolInfo.tickUpper = newTickUpper;
    }

    /**
     * Removes liquidity from our BidWall position.
     *
     * @param _key The {PoolKey} that is being modified
     * @param _nativeIsZero If our native token is `currency0`
     * @param _tickLower The lower tick of our BidWall position
     * @param _tickUpper The upper tick of our BidWall position
     *
     * @return ethWithdrawn_ The amount of native token withdrawn
     * @return memecoinWithdrawn_ The amount of Memecoin withdrawn
     */
    function _removeLiquidity(
        PoolKey memory _key,
        bool _nativeIsZero,
        int24 _tickLower,
        int24 _tickUpper
    ) internal returns (
        uint ethWithdrawn_,
        uint memecoinWithdrawn_
    ) {
        // Get our existing liquidity for the position
        (uint128 liquidityBefore,,) = poolManager.getPositionInfo({
            poolId: _key.toId(),
            owner: address(this),
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            salt: 'bidwall'
        });

        BalanceDelta delta = _modifyAndSettleLiquidity({
            _poolKey: _key,
            _tickLower: _tickLower,
            _tickUpper: _tickUpper,
            _liquidityDelta: -int128(liquidityBefore),
            _sender: address(this)
        });

        // Set our ETH and Memecoin withdrawn amounts, depending on if the native token is currency0
        (ethWithdrawn_, memecoinWithdrawn_) = _nativeIsZero
            ? (uint128(delta.amount0()), uint128(delta.amount1()))
            : (uint128(delta.amount1()), uint128(delta.amount0()));
    }

    /**
     * This function will only be called by other functions via the PositionManager, which will already
     * hold the Uniswap V4 PoolManager key. It is for this reason we can interact openly with the
     * Uniswap V4 protocol without requiring a separate callback.
     *
     * @param _poolKey The {PoolKey} that is being modified
     * @param _tickLower The lower tick of our BidWall position
     * @param _tickUpper The upper tick of our BidWall position
     * @param _liquidityDelta The liquidity delta modifying the position
     * @param _sender The address that will be sending or receiving tokens
     */
    function _modifyAndSettleLiquidity(
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityDelta,
        address _sender
    ) internal returns (
        BalanceDelta delta_
    ) {
        (delta_, ) = poolManager.modifyLiquidity({
            key: _poolKey,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: _liquidityDelta,
                salt: 'bidwall'
            }),
            hookData: ''
        });

        if (delta_.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, _sender, uint128(-delta_.amount0()), false);
        } else if (delta_.amount0() > 0) {
            poolManager.take(_poolKey.currency0, _sender, uint128(delta_.amount0()));
        }

        if (delta_.amount1() < 0) {
            _poolKey.currency1.settle(poolManager, _sender, uint128(-delta_.amount1()), false);
        } else if (delta_.amount1() > 0) {
            poolManager.take(_poolKey.currency1, _sender, uint128(delta_.amount1()));
        }
    }

    /**
     * Defines our swap fee thresholds that must be crossed to provide fees. Each time
     * that we hit a set `cumulativeSwapFees` amount, we release a threshold of fees into
     * the bid wall.
     *
     * For this fixed threshold, this will just return the value set in `setSwapFeeThreshold`.
     *
     * @return uint The swap fee threshold
     */
    function _getSwapFeeThreshold(uint) internal virtual view returns (uint) {
        return _swapFeeThreshold;
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override virtual returns (bool) {
        return true;
    }

    /**
     * Ensures that only a {PositionManager} can call the function.
     */
    modifier onlyPositionManager {
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) revert NotPositionManager();
        _;
    }

}
