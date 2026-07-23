// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {BaseSubscriber} from '@flaunch/subscribers/Base.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';

import {IBuyBackAndBurnFlay} from '@flaunch-interfaces/IBuyBackAndBurnFlay.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';

/**
 * Collects ETH and flETH from external contracts and when a certain threshold is reached
 * then the total amount will be spent on buying $FLAY token from a specified PoolKey and
 * burning it.
 */
contract BuyBackAndBurnFlay is IBuyBackAndBurnFlay, BaseSubscriber, Ownable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickFinder for int24;

    /// The `dEaD` address to burn our $FLAY tokens to
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// The amount of ETH that must be reached before buying $FLAY
    uint public ethThreshold;

    /// The FLETH contract that is used by the Flaunch protocol
    IFLETH public immutable fleth;

    /// The $FLAY PoolKey that we will be making buys against
    PoolKey public flayPoolKey;

    /// The {PoolManager} contract
    IPoolManager public immutable poolManager;

    /// The buy position information
    PositionInfo public positionInfo;

    /// Stores the last recorded ETH balance for event emissions
    uint internal _storedEthBalance;

    /**
     * Sets our {Notifier} to parent contract to lock down calls and references our FLETH
     * contract address.
     */
    constructor(
        address _fleth,
        address _poolManager,
        address _notifier
    ) BaseSubscriber(_notifier) {
        fleth = IFLETH(_fleth);
        poolManager = IPoolManager(_poolManager);

        // Set our initial ETH threshold and emit the corresponding event
        ethThreshold = 1 ether;
        emit ThresholdUpdated(ethThreshold);

        _initializeOwner(msg.sender);
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * We have no subscription requirements, so we can just confirm immediately.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(
        bytes memory /* _data */
    ) public view override(BaseSubscriber, IBuyBackAndBurnFlay) onlyNotifier returns (bool) {
        return true;
    }

    /**
     * If we have reached a specific threshold of combined ETH and flETH then we make a swap
     * to buy $FLAY tokens and then burn them.
     *
     * @dev Called when `afterSwap` is triggered.
     *
     * @param _key The notification key
     */
    function notify(
        PoolId,
        /* _poolId */
        bytes4 _key,
        bytes calldata /* _data */
    ) public override(BaseSubscriber, IBuyBackAndBurnFlay) onlyNotifier {
        // We only want to deal with the `afterSwap` key
        if (_key != IHooks.afterSwap.selector) {
            return;
        }

        // Find the combined balance of flETH (ETH will be converted to flETH on receipt)
        uint ethBalance = fleth.balanceOf(address(this));

        // If the eth balance has changed since the last time we hit this notification, then we
        // want to send an updated event to notify.

        // Confirm that we have surpassed the defined threshold
        if (ethBalance < ethThreshold) {
            // If we have not crossed the threshold, then we won't hit this check at the end of
            // this function call due to exiting early. For this reason we call it within this
            // conditional.
            _emitEthBalance(ethBalance);
            return;
        }

        // Confirm that we have a valid PoolKey
        if (flayPoolKey.tickSpacing == 0) {
            _emitEthBalance(ethBalance);
            return;
        }

        /**
         * We need to create a liquidity position that puts ETH into a position. This means
         * that we will be creating a token buy position 1 tick under the current, just like
         * the {BidWall} contract does.
         *
         * If we have an existing position then we need to withdraw from this and recreate
         * the position with the combined ETH.
         */

        // Check if the native token is `currency0`
        bool nativeIsZero = address(fleth) == Currency.unwrap(flayPoolKey.currency0);

        // If our position has already been initialized, then we need to remove any
        // existing liquidity to get any earned FLAY and recover any unspent ETH.
        if (positionInfo.initialized) {
            // Get our existing liquidity for the position
            (uint128 liquidityBefore,,) = poolManager.getPositionInfo({
                poolId: flayPoolKey.toId(),
                owner: address(this),
                tickLower: positionInfo.tickLower,
                tickUpper: positionInfo.tickUpper,
                salt: ''
            });

            // Remove the current liquidity from our position
            _modifyAndSettleLiquidity({
                _tickLower: positionInfo.tickLower, _tickUpper: positionInfo.tickUpper, _liquidityDelta: -int128(liquidityBefore)
            });
        } else {
            // Mark our position as initialized
            positionInfo.initialized = true;
        }

        // Increase our spent balance
        positionInfo.spent += ethBalance;

        // If we have any FLAY tokens held in our contract, then we want to burn them
        Currency flayToken = (nativeIsZero) ? flayPoolKey.currency1 : flayPoolKey.currency0;
        uint tokenBalance = flayToken.balanceOfSelf();
        if (tokenBalance != 0) {
            flayToken.transfer(BURN_ADDRESS, tokenBalance);
            positionInfo.burned += tokenBalance;
            emit BurnBabyBurn(tokenBalance);
        }

        // Get the current tick from the pool
        (, int24 currentTick,,) = poolManager.getSlot0(flayPoolKey.toId());

        // Determine a base tick just outside of the current tick
        int24 baseTick = nativeIsZero ? currentTick + 1 : currentTick - 1;

        // Calculate the new tick range and liquidity values
        int24 newTickLower;
        int24 newTickUpper;
        uint128 liquidityDelta;

        if (nativeIsZero) {
            newTickLower = baseTick.validTick(false);
            newTickUpper = newTickLower + TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount0({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount0: ethBalance
            });
        } else {
            newTickUpper = baseTick.validTick(true);
            newTickLower = newTickUpper - TickFinder.TICK_SPACING;
            liquidityDelta = LiquidityAmounts.getLiquidityForAmount1({
                sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                amount1: ethBalance
            });
        }

        // Modify the liquidity to add our position
        _modifyAndSettleLiquidity({_tickLower: newTickLower, _tickUpper: newTickUpper, _liquidityDelta: int128(liquidityDelta)});

        // Update the position tick range
        positionInfo.tickLower = newTickLower;
        positionInfo.tickUpper = newTickUpper;

        // After modifying liquidity, check our updated ETH balance
        _emitEthBalance(fleth.balanceOf(address(this)));
    }

    /**
     * Updates the ETH threshold that must be reached to trigger a buy back.
     *
     * @dev This can only be called by the contract Owner.
     *
     * @param _ethThreshold The new ETH threshold
     */
    function setEthThreshold(
        uint _ethThreshold
    ) public onlyOwner {
        ethThreshold = _ethThreshold;
        emit ThresholdUpdated(_ethThreshold);
    }

    /**
     * Updates the $FLAY PoolKey that actions the swap.
     *
     * @dev This can only be called by the contract Owner.
     *
     * @param _poolKey The new ETH threshold
     */
    function setPoolKey(
        PoolKey memory _poolKey
    ) public onlyOwner {
        flayPoolKey = _poolKey;
        emit PoolKeyUpdated(_poolKey);
    }

    /**
     * This function will only be called by other functions via the PositionManager, which will already
     * hold the Uniswap V4 PoolManager key. It is for this reason we can interact openly with the
     * Uniswap V4 protocol without requiring a separate callback.
     *
     * @param _tickLower The lower tick of our BidWall position
     * @param _tickUpper The upper tick of our BidWall position
     * @param _liquidityDelta The liquidity delta modifying the position
     */
    function _modifyAndSettleLiquidity(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityDelta
    ) internal {
        (BalanceDelta delta_,) = poolManager.modifyLiquidity({
            key: flayPoolKey,
            params: ModifyLiquidityParams({tickLower: _tickLower, tickUpper: _tickUpper, liquidityDelta: _liquidityDelta, salt: ''}),
            hookData: ''
        });

        if (delta_.amount0() < 0) {
            flayPoolKey.currency0.settle(poolManager, address(this), uint128(-delta_.amount0()), false);
        } else if (delta_.amount0() > 0) {
            poolManager.take(flayPoolKey.currency0, address(this), uint128(delta_.amount0()));
        }

        if (delta_.amount1() < 0) {
            flayPoolKey.currency1.settle(poolManager, address(this), uint128(-delta_.amount1()), false);
        } else if (delta_.amount1() > 0) {
            poolManager.take(flayPoolKey.currency1, address(this), uint128(delta_.amount1()));
        }
    }

    /**
     * Checks the flETH balance held by the contract and emits an event if it has changed.
     */
    function _emitEthBalance(
        uint _ethBalance
    ) internal {
        if (_ethBalance == _storedEthBalance) {
            return;
        }

        // Update our internally stored ETH balance and emit our event
        _storedEthBalance = _ethBalance;
        emit EthBalanceUpdated(_ethBalance);
    }

    /**
     * The contract should be able to receive ETH from any source.
     */
    receive() external payable {
        // Convert any ETH that we receive into FLETH
        fleth.deposit{value: msg.value}(0);
    }
}
