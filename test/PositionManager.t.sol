// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {Vm} from 'forge-std/Vm.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from './FlaunchTest.sol';
import {IFlaunch} from '@flaunch-interfaces/IFlaunch.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract PositionManagerTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    constructor() {
        // Deploy our platform
        _deployPlatform();
    }

    function test_CanGetDefaultSettings() public view {
        // Set our default sqrtPriceX96 that tokens will start at
        assertEq(initialPrice.getSqrtPriceX96(address(this), false, abi.encode('')), FL_SQRT_PRICE_1_2);
        assertEq(initialPrice.getSqrtPriceX96(address(this), true, abi.encode('')), FL_SQRT_PRICE_2_1);
    }

    function test_CanFlaunch(
        uint24 _creatorFeeAllocation,
        bool _flipped
    ) public flipTokens(_flipped) {
        vm.assume(_creatorFeeAllocation <= 100_00);

        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Reflaunch seeds the full INITIAL_SUPPLY into the pool as an immutable single-sided
        // position, so the PositionManager itself holds no memecoin after flaunch completes.
        assertEq(IERC20(memecoin).balanceOf(address(positionManager)), 0);

        PoolKey memory poolKey = positionManager.poolKey(memecoin);
        uint tokenId = flaunch.tokenId(memecoin);

        assertEq(Currency.unwrap(poolKey.currency0), _flipped ? memecoin : address(WETH));
        assertEq(Currency.unwrap(poolKey.currency1), _flipped ? address(WETH) : memecoin);
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 60);
        assertEq(address(poolKey.hooks), address(positionManager));

        assertEq(IMemecoin(memecoin).name(), 'Token Name');
        assertEq(IMemecoin(memecoin).symbol(), 'TOKEN');
        assertEq(IMemecoin(memecoin).tokenURI(), 'https://flaunch.gg/');
        assertEq(flaunch.ownerOf(tokenId), address(this));
        assertEq(flaunch.memecoin(tokenId), memecoin);
        assertEq(flaunch.tokenURI(tokenId), 'https://api.flaunch.gg/token/1');
    }

    /**
     * F-7 regression: the Oracle ring buffer must be seeded with one observation as soon as
     * `flaunch()` initialises the pool. Without this, `Oracle.twapTick` falls back to the spot
     * tick on the first ISP fill (cardinality == 0 branch) — defeating the manipulation-resistant
     * pricing intent for the very first swap.
     */
    function test_F7_FlaunchSeedsOracleObservation() public {
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        PoolId poolId = positionManager.poolKey(memecoin).toId();

        // Immediately after `flaunch()`, the oracle should hold exactly one observation seeded
        // at the launch tick. With this in place, the first ISP fill consults the TWAP path
        // instead of the warm-up `_currentTick` fallback.
        assertEq(oracle.observationState(poolId).cardinality, 1, 'oracle not seeded at init');
        assertEq(oracle.observationState(poolId).index, 0, 'oracle cursor not at slot 0');
    }

    function test_CanMassFlaunch(
        uint8 flaunchCount,
        bool _flipped
    ) public flipTokens(_flipped) {
        for (uint i; i < flaunchCount; ++i) {
            positionManager.flaunch(
                IPositionManager.FlaunchParams({
                    name: 'Token Name',
                    symbol: 'TOKEN',
                    tokenUri: 'https://flaunch.gg/',
                    premineAmount: 0,
                    creator: address(this),
                    creatorFeeAllocation: 50_00,
                    flaunchAt: 0,
                    initialPriceParams: abi.encode(''),
                    feeCalculatorParams: abi.encode(1_000)
                })
            );
        }
    }

    // Test that only the owner can call setInitialPrice
    function test_CanOnlySetInitialPriceAsOwner() public {
        // Call as non-owner, should revert
        vm.startPrank(address(1));
        vm.expectRevert(UNAUTHORIZED);
        positionManager.setInitialPrice(address(initialPrice));
        vm.stopPrank();

        // Call as owner, should succeed
        positionManager.setInitialPrice(address(initialPrice));
    }

    // Test setting a valid InitialPrice contract
    function test_CanSetValidInitialPrice() public {
        // Set valid InitialPrice contract
        positionManager.setInitialPrice(address(initialPrice));

        // Ensure the contract state was updated correctly
        assertEq(address(positionManager.initialPrice()), address(initialPrice), 'Initial price contract should be set correctly');
    }

    // Test that InitialPriceUpdated event is emitted when the initial price is set
    function test_CanGetInitialPriceUpdatedEvent() public {
        // Expect the InitialPriceUpdated event
        vm.expectEmit();
        emit IPositionManager.InitialPriceUpdated(address(initialPrice));

        // Call as owner to set valid InitialPrice and emit event
        positionManager.setInitialPrice(address(initialPrice));
    }

    function test_CanScheduleFlaunch() public {
        uint expectedFlaunchAt = block.timestamp + 15 days;

        // Capture logs because (a) the actual poolId depends on the memecoin address
        // assigned during flaunch (so cannot be hardcoded) and (b) the swap path emits
        // other events that trip vm.expectEmit's strict next-emit check.
        vm.recordLogs();
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: expectedFlaunchAt,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        PoolId poolId = positionManager.poolKey(memecoin).toId();
        _assertPoolScheduledLogged(vm.getRecordedLogs(), poolId, expectedFlaunchAt);
        assertEq(positionManager.flaunchesAt(poolId), expectedFlaunchAt);
    }

    function _assertPoolScheduledLogged(
        Vm.Log[] memory logs,
        PoolId _poolId,
        uint _flaunchesAt
    ) internal {
        bytes32 sig = IPositionManager.PoolScheduled.selector;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(positionManager)) {
                continue;
            }
            if (logs[i].topics[1] != PoolId.unwrap(_poolId)) {
                continue;
            }
            uint loggedAt = abi.decode(logs[i].data, (uint));
            assertEq(loggedAt, _flaunchesAt, 'PoolScheduled flaunchesAt mismatch');
            return;
        }
        revert('PoolScheduled not emitted');
    }

    function test_CannotScheduleFlaunchWithLargeDuration(
        uint _duration
    ) public {
        vm.assume(_duration > flaunch.MAX_SCHEDULE_DURATION());

        vm.expectRevert();
        positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: block.timestamp + _duration,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanCaptureDelta() public {
        int amount0;
        int amount1;

        address TOKEN = address(1);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        });

        PoolKey memory flippedPoolKey = PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(address(WETH)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        });

        // This is ETH -> TOKEN on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), 1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        (amount0, amount1) = positionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is ETH -> TOKEN on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = positionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);
    }

    function test_CanBurn721IfCreator() public {
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        flaunch.burn(flaunch.tokenId(memecoin));
    }

    function test_CanBurn721IfApproved() public {
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = flaunch.tokenId(memecoin);

        address approvedCaller = address(1);
        flaunch.approve(approvedCaller, tokenId);

        vm.prank(approvedCaller);
        flaunch.burn(tokenId);
    }

    function test_CannotBurn721IfNotCreatorOrApproved() public {
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = flaunch.tokenId(memecoin);

        address unapprovedCaller = address(1);

        vm.prank(unapprovedCaller);
        vm.expectRevert(bytes4(0x4b6e7f18)); // NotOwnerNorApproved()
        flaunch.burn(tokenId);
    }

    function test_CannotFlaunchWithInvalidCreatorFeeAllocation(
        uint24 _creatorFeeAllocation
    ) public {
        vm.assume(_creatorFeeAllocation > 100_00);

        vm.expectRevert(
            abi.encodeWithSelector(IFlaunch.CreatorFeeAllocationInvalid.selector, _creatorFeeAllocation, flaunch.MAX_CREATOR_ALLOCATION())
        );
        positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanCaptureHookSwapEvents() public {
        // Flaunch our new token
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 0,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get the {PoolKey} that we will swap against
        PoolKey memory poolKey = positionManager.poolKey(memecoin);

        flETH.deposit{value: 100 ether}();

        // Provide this test contract enough flETH to make the swap
        flETH.approve(address(poolSwap), type(uint).max);

        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        flETH.transfer(address(poolManager), 50 ether);

        // Mock a deposit into the ISP
        // deal(memecoin, address(positionManager), IERC20(memecoin).balanceOf(positionManager) + 0.5 ether);
        flETH.transfer(address(positionManager), 0.5 ether);
        positionManager.depositFeesMock(poolKey, 0.5 ether, 0.5 ether);

        // The swap also emits DelegateVotesChanged from the memecoin contract which trips
        // vm.expectEmit's strict next-emit check; capture all logs and scan for the events.
        // Under the reflaunch flow the deposited ISP fees do not consume in this scenario,
        // so the PoolSwap event records the full swap through the Uniswap path.
        vm.recordLogs();
        poolSwap.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -20 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertPoolSwapLogged(
            logs,
            poolKey.toId(),
            PoolSwapExpect({
                flAmount0: 0,
                flAmount1: 0,
                flFee0: 0,
                flFee1: 0,
                ispAmount0: 0,
                ispAmount1: 0,
                ispFee0: 0,
                ispFee1: 0,
                uniAmount0: -20000000000000000000,
                uniAmount1: 39872935100675998680,
                uniFee0: 0,
                uniFee1: -398729351006759986
            })
        );
    }

    struct PoolSwapExpect {
        int flAmount0;
        int flAmount1;
        int flFee0;
        int flFee1;
        int ispAmount0;
        int ispAmount1;
        int ispFee0;
        int ispFee1;
        int uniAmount0;
        int uniAmount1;
        int uniFee0;
        int uniFee1;
    }

    function _assertPoolSwapLogged(
        Vm.Log[] memory logs,
        PoolId _poolId,
        PoolSwapExpect memory _exp
    ) internal {
        bytes32 sig = IPositionManager.PoolSwap.selector;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(positionManager)) {
                continue;
            }
            if (logs[i].topics[1] != PoolId.unwrap(_poolId)) {
                continue;
            }
            PoolSwapExpect memory got = abi.decode(logs[i].data, (PoolSwapExpect));
            assertEq(got.flAmount0, _exp.flAmount0, 'flAmount0 mismatch');
            assertEq(got.flAmount1, _exp.flAmount1, 'flAmount1 mismatch');
            assertEq(got.flFee0, _exp.flFee0, 'flFee0 mismatch');
            assertEq(got.flFee1, _exp.flFee1, 'flFee1 mismatch');
            assertEq(got.ispAmount0, _exp.ispAmount0, 'ispAmount0 mismatch');
            assertEq(got.ispAmount1, _exp.ispAmount1, 'ispAmount1 mismatch');
            assertEq(got.ispFee0, _exp.ispFee0, 'ispFee0 mismatch');
            assertEq(got.ispFee1, _exp.ispFee1, 'ispFee1 mismatch');
            assertEq(got.uniAmount0, _exp.uniAmount0, 'uniAmount0 mismatch');
            assertEq(got.uniAmount1, _exp.uniAmount1, 'uniAmount1 mismatch');
            assertEq(got.uniFee0, _exp.uniFee0, 'uniFee0 mismatch');
            assertEq(got.uniFee1, _exp.uniFee1, 'uniFee1 mismatch');
            return;
        }
        revert('PoolSwap not emitted');
    }
}
