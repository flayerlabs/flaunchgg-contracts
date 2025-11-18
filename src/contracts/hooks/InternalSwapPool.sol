// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';


/**
 * This frontruns Uniswap to sell undesired token amounts from our fees into desired tokens
 * ahead of our fee distribution. This acts as a partial orderbook to remove impact against
 * our pool.
 * 这个钩子提前运行Uniswap，将不需要的代币数量从我们的费用中出售到所需的代币，以便在我们进行费用分配之前。
 * 这作为部分订单簿来减少对我们池的影响。
 */
abstract contract InternalSwapPool {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Emitted when a pool has been allocated fees on either side of the position
    event PoolFeesReceived(PoolId indexed _poolId, uint _amount0, uint _amount1);

    /// Emitted when a pool fees have been distributed to stakers
    event PoolFeesDistributed(PoolId indexed _poolId, uint _donateAmount, uint _creatorAmount, uint _bidWallAmount, uint _governanceAmount, uint _protocolAmount);

    /// Emitted when pool fees have been internally swapped
    event PoolFeesSwapped(PoolId indexed _poolId, bool zeroForOne, uint _amount0, uint _amount1);

    /**
     * Contains amounts for both the currency0 and currency1 values of a UV4 Pool.
     * 包含UV4池的currency0和currency1值的金额。
     */
    struct ClaimableFees {
        uint amount0;
        uint amount1;
    }

    /// Maps the amount of claimable tokens that are available to be `distributed`
    /// for a `PoolId`. 映射可分配的代币数量，用于`PoolId`。
    mapping (PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    /**
     * Provides the {ClaimableFees} for a pool key.
     * 提供池键的{ClaimableFees}。
     * @param _poolKey The PoolKey to check
     *
     * @return The {ClaimableFees} for the PoolKey
     */
    function poolFees(PoolKey memory _poolKey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    /**
     * Allows for fees to be deposited against a pool to be distributed.
     * 允许对池进行存款以进行分配。
     * @dev Our `amount0` must always refer to the amount of the native token provided. The
     * `amount1` will always be the underlying {Memecoin}. The internal logic of
     * this function will rearrange them to match the `PoolKey` if needed.
     * 我们的`amount0`必须始终引用提供的原生代币的数量。`amount1`将始终是底层{Memecoin}。
     * 如果需要，此函数的内部逻辑将重新排列它们以匹配`PoolKey`。
     * @param _poolKey The PoolKey to deposit against
     * @param _amount0 The amount of eth equivalent to deposit
     * @param _amount1 The amount of underlying token to deposit
     */
    function _depositFees(PoolKey memory _poolKey, uint _amount0, uint _amount1) internal {
        PoolId _poolId = _poolKey.toId();

        _poolFees[_poolId].amount0 += _amount0;
        _poolFees[_poolId].amount1 += _amount1;

        emit PoolFeesReceived(_poolId, _amount0, _amount1);
    }

    /**
     * Check if we have any token1 fee tokens that we can use to fill the swap before it hits
     * the Uniswap pool. This prevents the pool from being affected and reduced gas costs.
     * 检查我们是否有任何token1代币，我们可以使用它们来填充交换，在它到达Uniswap池之前。
     * 这防止了池受到影响并减少了gas成本。
     * This frontruns UniSwap to sell undesired token amounts from our fees into desired tokens
     * ahead of our fee distribution. This acts as a partial orderbook to remove impact against
     * our pool.
     * 这提前运行Uniswap，将我们不需要的token数量从我们的费用中出售到我们想要的token，
     * 在我们收取费用之前。这作为一个部分订单簿来减少对我们池的影响。
     * @param _poolManager The Uniswap V4 {PoolManager} contract
     * @param _key The PoolKey that is being swapped against
     * @param _params The swap parameters
     * @param _nativeIsZero If our native token is `currency0`
     *
     * @return ethIn_ The ETH taken for the swap
     * @return tokenOut_ The tokens given for the swap
     */
    function _internalSwap(
        IPoolManager _poolManager,
        PoolKey calldata _key,
        IPoolManager.SwapParams memory _params,
        bool _nativeIsZero
    ) internal returns (
        uint ethIn_,
        uint tokenOut_
    ) {
        PoolId poolId = _key.toId();

        // Load our PoolFees as storage as we will manipulate them later if we trigger
        // 加载我们的PoolFees作为存储，因为我们稍后会在我们触发时操作它们。
        ClaimableFees storage pendingPoolFees = _poolFees[poolId];
        if (pendingPoolFees.amount1 == 0) {
            return (ethIn_, tokenOut_);
        }

        // We only want to process our internal swap if we are buying non-ETH tokens with ETH. This
        // will allow us to correctly calculate the amount of token to replace.
        // 我们只想处理我们的内部交换，如果我们用ETH购买非ETH代币。这将允许我们正确计算要替换的代币数量。
        if (_nativeIsZero != _params.zeroForOne) {
            return (ethIn_, tokenOut_);
        }

        // Get the current price for our pool 获取我们池的当前价格

        (uint160 sqrtPriceX96,,,) = _poolManager.getSlot0(poolId);

        // Since we have a positive amountSpecified, we can determine the maximum
        // amount that we can transact from our pool fees. 由于我们有一个正的amountSpecified，我们可以确定我们
        // 可以从我们的池费用中交易的最大金额。
        if (_params.amountSpecified >= 0) {
            // Take the max value of either the pool fees or the amount specified to swap for
            // 取池费用或指定的金额中的较大值来交换。
            uint amountSpecified = (uint(_params.amountSpecified) > pendingPoolFees.amount1)
                ? pendingPoolFees.amount1
                : uint(_params.amountSpecified);

            // Capture the amount of desired token required at the current pool state to
            // purchase the amount of token speicified, capped by the pool fees available.
            // 捕获在当前池状态下购买指定数量的所需token所需的金额，受可用池费用的限制。
            (, ethIn_, tokenOut_, ) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: _params.sqrtPriceLimitX96,
                liquidity: _poolManager.getLiquidity(poolId),
                amountRemaining: int(amountSpecified),
                feePips: 0
            });
        }
        // As we have a negative amountSpecified, this means that we are spending any amount
        // of token to get a specific amount of undesired token.
        // 由于我们有一个负的amountSpecified，这意味着我们花费任何数量的token来获得特定数量的不需要的token。
        else {
            // To calculate the amount of tokens that we can receive, we first pass in the amount
            // of ETH that we are requesting to spend. We need to invert the `sqrtPriceTargetX96`
            // as our swap step computation is essentially calculating the opposite direction.
            // 要计算我们可以接收的代币数量，我们首先传入我们请求花费的ETH数量。我们需要反转`sqrtPriceTargetX96`，
            // 因为我们的交换步骤计算基本上是计算相反的方向。
            (, tokenOut_, ethIn_, ) = SwapMath.computeSwapStep({
                sqrtPriceCurrentX96: sqrtPriceX96,
                sqrtPriceTargetX96: _params.zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
                liquidity: _poolManager.getLiquidity(poolId),
                amountRemaining: int(-_params.amountSpecified),
                feePips: 0
            });

            // If we cannot fulfill the full amount of the internal orderbook, then we want to
            // calculate the percentage of which we can utilize.
            // 如果我们不能满足内部订单簿的全部金额，那么我们想要计算我们可以利用的百分比。
            // 如果我们能满足全部金额，那么我们想要计算我们可以利用的百分比。
            if (tokenOut_ > pendingPoolFees.amount1) {
                ethIn_ = (pendingPoolFees.amount1 * ethIn_) / tokenOut_;
                tokenOut_ = pendingPoolFees.amount1;
            }
        }

        // If nothing has happened, we can exit
        if (ethIn_ == 0 && tokenOut_ == 0) {
            return (ethIn_, tokenOut_);
        }

        // Reduce the amount of fees that have been extracted from the pool and converted
        // into ETH fees.
        pendingPoolFees.amount0 += ethIn_;
        pendingPoolFees.amount1 -= tokenOut_;

        // Take the required ETH tokens from the {PoolManager} to settle the currency change. The
        // `tokensOut_` are settled externally to this call.
        _poolManager.take(!_nativeIsZero ? _key.currency1 : _key.currency0, address(this), ethIn_);
        (!_nativeIsZero ? _key.currency0 : _key.currency1).settle(_poolManager, address(this), tokenOut_, false);

        // Capture the swap cost that we captured from our drip
        emit PoolFeesSwapped(poolId, _params.zeroForOne, ethIn_, tokenOut_);
    }

}
