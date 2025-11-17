// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';

import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {BalanceDelta, toBalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';


/**
 * Adds functionality to the {PositionManager} that promotes a fair token launch.
 * 添加功能到{PositionManager}，促进公平代币启动。
 * This creates a time window right after the token is launched that keeps the token at
 * the same price in a single tick position. Fees earned from this are kept within the
 * position and cannot be sold into until the fair launch window has finished.
 * 这创建了一个时间窗口，在代币启动后，保持代币在单个tick位置的价格。
 * 从这笔交易中赚取的费用保持在位置中，不能在公平启动窗口结束前卖出。
 * Once the FairLaunch period has ended, the ETH raised and the remaining tokens are
 * both deployed into a Uniswap position to facilitate ongoing transactions and create
 * a price discovery.
 * 一旦公平启动窗口结束，筹集的ETH和剩余的代币都被部署到一个Uniswap位置，以促进持续交易和价格发现。
 *
 * @dev Based on: https://github.com/fico23/fundraise-hook
 */
contract FairLaunch is AccessControl {

    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickFinder for int24;

    error CannotModifyLiquidityDuringFairLaunch();
    error CannotSellTokenDuringFairLaunch();
    error NotPositionManager();

    /// Emitted when a Fair Launch position is created 当公平启动位置被创建时发出事件
    event FairLaunchCreated(PoolId indexed _poolId, uint _tokens, uint _startsAt, uint _endsAt);

    /// Emitted when a Fair Launch is ended and rebalanced 当公平启动结束并重新平衡时发出事件
    event FairLaunchEnded(PoolId indexed _poolId, uint _revenue, uint _supply, uint _endedAt);

    /**
     * Holds FairLaunch information for a Pool.
     * 持有池的公平启动信息。
     * @member startsAt The unix timestamp that the FairLaunch window starts
     * @member endsAt The unix timestamp that the FairLaunch window ends
     * @member initialTick The tick that the FairLaunch position was created at
     * @member revenue The amount of revenue earned by the FairLaunch position
     * @member supply The amount of supply in the FairLaunch
     * @member closed If the FairLaunch has been closed
     */
    struct FairLaunchInfo {
        uint startsAt;
        uint endsAt;
        int24 initialTick;
        uint revenue;
        uint supply;
        bool closed;
    }

    /// Maps a PoolId to a FairLaunchInfo struct 将PoolId映射到FairLaunchInfo结构体
    mapping (PoolId _poolId => FairLaunchInfo _info) internal _fairLaunchInfo;

    /// Our Uniswap V4 {PoolManager} contract address 我们的Uniswap V4 {PoolManager}合同地址
    IPoolManager public immutable poolManager;

    /**
     * Stores our native token.
     * 存储我们的原生代币。
     * @param _poolManager The Uniswap V4 {PoolManager} contract
     */
    constructor (IPoolManager _poolManager) {
        poolManager = _poolManager;

        // Set our caller to have the default admin of protocol roles
        // 设置我们的调用者为协议角色的默认管理员
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * Checks if the {PoolKey} is within the fair launch window.
     * 检查{PoolKey}是否在公平启动窗口内。
     * @param _poolId The ID of the PoolKey
     *
     * @return If the {PoolKey} is within the fair launch window
     */
    function inFairLaunchWindow(PoolId _poolId) public view returns (bool) {
        FairLaunchInfo memory info = _fairLaunchInfo[_poolId];
        return block.timestamp >= info.startsAt && block.timestamp < info.endsAt;
    }

    /**
     * Helper function to call the FairLaunchInfo struct for a pool.
     * 调用池的FairLaunchInfo结构体。
     * @param _poolId The ID of the PoolKey
     *
     * @return The FairLaunchInfo for the pool
     */
    function fairLaunchInfo(PoolId _poolId) public view returns (FairLaunchInfo memory) {
        return _fairLaunchInfo[_poolId];
    }

    /**
     * Creates an initial fair launch position.
     * 创建一个初始公平启动位置。
     * @param _poolId The ID for the pool being initialized
     * @param _initialTokenFairLaunch The amount of tokens to add as single sided fair launch liquidity
     */
    function createPosition(
        PoolId _poolId,
        int24 _initialTick,
        uint _flaunchesAt,
        uint _initialTokenFairLaunch,
        uint _fairLaunchDuration
    ) public virtual onlyPositionManager returns (
        FairLaunchInfo memory
    ) {
        // If we have no initial tokens, then we need to overwrite our fair launch duration to zero
        // 如果没有初始代币，那么我们需要将公平启动持续时间重写为零
        if (_initialTokenFairLaunch == 0) {
            _fairLaunchDuration = 0;
        }

        // Determine the time that the fair launch window will close
        // 确定公平启动窗口关闭的时间
        uint endsAt = _flaunchesAt + _fairLaunchDuration;

        // Map these tokens into an pseudo-escrow that we can reference during the sale
        // 将这些代币映射到一个伪-托管，我们可以在销售期间引用
        // and activate our pool fair launch window.
        // 并激活我们的池公平启动窗口。
        _fairLaunchInfo[_poolId] = FairLaunchInfo({
            startsAt: _flaunchesAt,
            endsAt: endsAt,
            initialTick: _initialTick,
            revenue: 0,
            supply: _initialTokenFairLaunch,
            closed: false
        });

        emit FairLaunchCreated(_poolId, _initialTokenFairLaunch, _flaunchesAt, endsAt);
        return _fairLaunchInfo[_poolId];
    }

    /**
     * Closes the FairLaunch position and recreates the position as a wide range position immediately
     * above the tick for our memecoin. This position is comprised of tokens not allocated to the
     * Fair Launch. Any unsold tokens from the Fair Launch will be burned.
     * 关闭公平启动位置，并立即重新创建一个位置，作为我们memecoin上方的一个宽范围位置。
     * 这个位置由未分配给公平启动的代币组成。公平启动未售出的代币将被销毁。
     * @param _poolKey The PoolKey we are closing the FairLaunch position of
     * @param _tokenFees The amount of token fees that need to remain in the {PositionManager}
     * @param _nativeIsZero If our native token is `currency0`
     */
    function closePosition(
        PoolKey memory _poolKey,
        uint _tokenFees,
        bool _nativeIsZero
    ) public onlyPositionManager returns (
        FairLaunchInfo memory
    ) {
        // Reference the pool's FairLaunchInfo, ready to store updated values
        FairLaunchInfo storage info = _fairLaunchInfo[_poolKey.toId()];

        int24 tickLower;
        int24 tickUpper;

        if (_nativeIsZero) {
            // ETH position
            tickLower = (info.initialTick + 1).validTick(false);
            tickUpper = tickLower + TickFinder.TICK_SPACING;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, true);

            // memecoin position (unsold fair launch supply gets burned in PositionManager)
            tickLower = TickFinder.MIN_TICK;
            tickUpper = (info.initialTick - 1).validTick(true);
            _createImmutablePosition(_poolKey, tickLower, tickUpper, _poolKey.currency1.balanceOf(msg.sender) - _tokenFees - info.supply, false);
        } else {
            // ETH position
            tickUpper = (info.initialTick - 1).validTick(true);
            tickLower = tickUpper - TickFinder.TICK_SPACING;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, false);

            // memecoin position (unsold fair launch supply gets burned in PositionManager)
            tickLower = (info.initialTick + 1).validTick(false);
            tickUpper = TickFinder.MAX_TICK;
            _createImmutablePosition(_poolKey, tickLower, tickUpper, _poolKey.currency0.balanceOf(msg.sender) - _tokenFees - info.supply, true);
        }

        // Mark our position as closed
        info.endsAt = block.timestamp;
        info.closed = true;

        // Emit the event with the balance of the currency we hold before we create a position with
        // it. We determine the end time by seeing if it has ended early, or if we are past the point
        // it was meant to end then we backdate it.
        emit FairLaunchEnded(_poolKey.toId(), info.revenue, info.supply, info.endsAt);

        return info;
    }

    /**
     * When we are filling from our Fair Launch position, we will always be buying tokens
     * with ETH. The amount specified that is passed in, however, could be positive or negative.
     * 当我们从我们的公平启动位置填充时，我们总是用ETH购买代币。然而，传入的数量可能是正数或负数。
     * The positive / negative flag will require us to calculate the amount the user will get in
     * a different way. Positive: How much ETH it costs to get amount. Negative: How many tokens
     * I can get for amount.
     * 正数/负数标志将要求我们以不同的方式计算用户将获得的数量。正数：获得数量所需的ETH数量。负数：获得数量所需的代币数量。
     * The amount requested **can** exceed the Fair Launch position, but we will additionally
     * have to call `_closeFairLaunchPosition` to facilitate it during this call. This will
     * provide additional liquidity before the swap actually takes place.
     * 请求的数量**可以**超过公平启动位置，但我们还需要调用`_closeFairLaunchPosition`来促进它在这笔交易期间。
     * 这将提供额外的流动性，在交换实际发生之前。
     * @dev `zeroForOne` will always be equal to `_nativeIsZero` as it will always be ETH -> Token.
     * @dev `zeroForOne`将始终等于`_nativeIsZero`，因为它总是ETH -> Token。
     * @param _poolKey The PoolKey we are filling from
     * @param _amountSpecified The amount specified in the swap
     * @param _nativeIsZero If our native token is `currency0`
     *
     * @return beforeSwapDelta_ The modified swap delta
     */
    function fillFromPosition(
        PoolKey memory _poolKey,
        int _amountSpecified,
        bool _nativeIsZero
    ) public onlyPositionManager returns (
        BeforeSwapDelta beforeSwapDelta_,
        BalanceDelta balanceDelta_,
        FairLaunchInfo memory fairLaunchInfo_
    ) {
        PoolId poolId = _poolKey.toId();
        FairLaunchInfo storage info = _fairLaunchInfo[poolId];

        // No tokens, no fun.
        if (_amountSpecified == 0) {
            return (beforeSwapDelta_, balanceDelta_, info);
        }

        uint ethIn;
        uint tokensOut;

        // If we have a negative amount specified, then we have an ETH amount passed in and want
        // to buy as many tokens as we can for that price.
        if (_amountSpecified < 0) {
            ethIn = uint(-_amountSpecified);
            tokensOut = _getQuoteAtTick(
                info.initialTick,
                ethIn,
                Currency.unwrap(_nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
                Currency.unwrap(_nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
            );
        }
        // Otherwise, if we have a positive amount specified, then we know the number of tokens that
        // are being purchased and need to calculate the amount of ETH required.
        else {
            tokensOut = uint(_amountSpecified);
            ethIn = _getQuoteAtTick(
                info.initialTick,
                tokensOut,
                Currency.unwrap(!_nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
                Currency.unwrap(!_nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
            );
        }

        // If the user has requested more tokens than are available in the fair launch, then we
        // need to strip back the amount that we can fulfill.
        if (tokensOut > info.supply) {
            // Calculate the percentage of tokensOut relative to the threshold and reduce the `ethIn`
            // value by the same amount. There may be some slight accuracy loss, but it's all good.
            uint percentage = info.supply * 1e18 / tokensOut;
            ethIn = (ethIn * percentage) / 1e18;

            // Update our `tokensOut` to the supply limit
            tokensOut = info.supply;
        }

        // Get our BeforeSwapDelta response ready
        beforeSwapDelta_ = (_amountSpecified < 0)
            ? toBeforeSwapDelta(ethIn.toInt128(), -tokensOut.toInt128())
            : toBeforeSwapDelta(-tokensOut.toInt128(), ethIn.toInt128());

        // Define our BalanceDelta
        balanceDelta_ = toBalanceDelta(
            _nativeIsZero ? ethIn.toInt128() : -tokensOut.toInt128(),
            _nativeIsZero ? -tokensOut.toInt128() : ethIn.toInt128()
        );

        info.revenue += ethIn;
        info.supply -= tokensOut;

        return (beforeSwapDelta_, balanceDelta_, info);
    }

    /**
     * Allows calls from the {PositionManager} to modify the amount of revenue stored against a pool's
     * FairLaunch position. This is required to correctly attribute fees taken.
     * 允许来自{PositionManager}的调用修改存储在池的公平启动位置上的收入。这是正确归因所收取费用所必需的。
     * @param _poolId The ID of the PoolKey
     * @param _revenue The revenue amount to add or subtract
     */
    function modifyRevenue(PoolId _poolId, int _revenue) public onlyPositionManager {
        if (_revenue < 0) {
            _fairLaunchInfo[_poolId].revenue -= uint(-_revenue);
        } else if (_revenue > 0) {
            _fairLaunchInfo[_poolId].revenue += uint(_revenue);
        }
    }

    /**
     * Creates an immutable, single-sided position when the FairLaunch window is closed.
     * 在公平启动窗口关闭时创建一个不可变的单边位置。
     * @param _poolKey The PoolKey to create a position against
     * @param _tickLower The lower tick of the position
     * @param _tickUpper The upper tick of the position
     * @param _tokens The number of tokens to put into the position
     * @param _tokenIsZero True if the position is created `currency0`; false is `currency1`
     */
    function _createImmutablePosition(
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint _tokens,
        bool _tokenIsZero
    ) internal {
        // Calculate the liquidity delta based on the tick range and token amount
        uint128 liquidityDelta = _tokenIsZero ? LiquidityAmounts.getLiquidityForAmount0({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
            amount0: _tokens
        }) : LiquidityAmounts.getLiquidityForAmount1({
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
            amount1: _tokens
        });

        // If we have no liquidity, then exit before creating the position which would revert
        if (liquidityDelta == 0) return;

        // Create our single-sided position
        (BalanceDelta delta,) = poolManager.modifyLiquidity({
            key: _poolKey,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: liquidityDelta.toInt128(),
                salt: ''
            }),
            hookData: ''
        });

        // Settle the tokens that are required to fill the position
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, msg.sender, uint(-int(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            _poolKey.currency1.settle(poolManager, msg.sender, uint(-int(delta.amount1())), false);
        }
    }

    /**
     * Given a tick and a token amount, calculates the amount of token received in exchange.
     * 给定一个tick和代币数量，计算获得的代币数量。
     * @dev Forked from the `Uniswap/v3-periphery` {OracleLibrary} contract.
     *
     * @param _tick Tick value used to calculate the quote
     * @param _baseAmount Amount of token to be converted
     * @param _baseToken Address of an ERC20 token contract used as the baseAmount denomination
     * @param _quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
     *
     * @return quoteAmount_ Amount of quoteToken received for baseAmount of baseToken
     */
    function _getQuoteAtTick(
        int24 _tick,
        uint _baseAmount,
        address _baseToken,
        address _quoteToken
    ) internal pure returns (
        uint quoteAmount_
    ) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);

        // Calculate `quoteAmount` with better precision if it doesn't overflow when multiplied
        // by itself.
        if (sqrtPriceX96 <= type(uint128).max) {
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX192, _baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, _baseAmount, ratioX192);
        } else {
            uint ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX128, _baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, _baseAmount, ratioX128);
        }
    }

    /**
     * Ensures that only a {PositionManager} can call the function.
     * 确保只有{PositionManager}可以调用函数。
     */
    modifier onlyPositionManager {
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) revert NotPositionManager();
        _;
    }

}
