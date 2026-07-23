// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {MemecoinMock} from 'test/mocks/MemecoinMock.sol';

import {Vm} from 'forge-std/Vm.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IBidWall} from '@flaunch-interfaces/IBidWall.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract BidWallTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for PoolManager;

    PoolKey poolKey;

    address alice;
    address memecoinTreasury;

    MemecoinMock memecoin;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        address _memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );
        memecoin = MemecoinMock(_memecoin);

        uint tokenId = flaunch.tokenId(_memecoin);

        // Register the treasury
        memecoinTreasury = flaunch.memecoinTreasury(tokenId);

        // Define Alice address and give her fat stacks
        alice = makeAddr('alice');
        memecoin.mint(alice, 100_000_000 ether);
        deal(address(WETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        memecoin.approve(address(poolSwap), type(uint).max);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        WETH.approve(address(poolSwap), type(uint).max);
        vm.stopPrank();

        // Set low BidWall threshold for testing
        bidWall.setSwapFeeThreshold(0.001 ether);
    }

    function setUp() public {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });
    }

    function test_CanDisableWithCreator() external {
        // initialially the hook should be enabled
        (bool isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, false);

        vm.expectEmit();
        emit IBidWall.BidWallDisabledStateUpdated(poolKey.toId(), true);

        // it should update the hook disabled status
        bidWall.setDisabledState({_key: poolKey, _disable: true});
        (isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, true);

        vm.expectEmit();
        emit IBidWall.BidWallDisabledStateUpdated(poolKey.toId(), false);

        // enable back the hook
        bidWall.setDisabledState({_key: poolKey, _disable: false});
        (isHookDisabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(isHookDisabled, false);
    }

    function test_CannotDisableWithoutCreator() external {
        vm.prank(address(1));
        vm.expectRevert(IBidWall.CallerIsNotCreator.selector);
        bidWall.setDisabledState({_key: poolKey, _disable: true});
    }

    function test_CannotDisableBidWallWithInvalidPoolKey(
        uint24 _invalidFee
    ) public {
        // Update our PoolKey to modify the fee to be different. This should invalidate the PoolId
        // that is generated and prevent the BidWall from disabling. The maximum value is also set
        // as defined in the {PoolKey} struct definition.
        vm.assume(_invalidFee != poolKey.fee && _invalidFee < 1_000_000);
        poolKey.fee = _invalidFee;

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.UnknownPool.selector, poolKey.toId()));
        bidWall.setDisabledState({_key: poolKey, _disable: true});
    }

    function test_CannotCallCloseBidWallDirectly() external {
        vm.expectRevert(IBidWall.NotPositionManager.selector);
        bidWall.closeBidWall(poolKey);
    }

    function test_CanPassFeesToTreasuryWhenHookIsDisabled() external poolHasLiquidity {
        // Disable the hook via a treasury call
        bidWall.setDisabledState(poolKey, true);

        // Make a swap as alice
        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: true, amountSpecified: 5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // The swap fee won't have been transferred, but instead allocated
        assertEq(positionManager.feeEscrow().balances(memecoinTreasury), 0.011277785202558418 ether);

        // Check the pool has no pending fees for the bidwall
        (,,,, uint pendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, 0);
    }

    function test_CanStoreFeeAllocationInInternalSwapPoolWhenETHIsSpecifiedToken() external poolHasLiquidity {
        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: false, amountSpecified: 5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}));
        vm.stopPrank();

        // Check the pool pending fees for the bidwall. Fees will have gone into
        // an internal swap pool at this point, so won't yet be seen.
        (,,,, uint pendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, 0);
    }

    function test_CanFundBidWallWithFees(
        bool _flipped
    ) external flipTokens(_flipped) {
        /**
         *
         */

        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        deal(address(WETH), address(poolManager), 1000e27 ether);

        // Create our memecoin now that we have might have flipped.
        address _memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );
        memecoin = MemecoinMock(_memecoin);
        memecoinTreasury = flaunch.memecoinTreasury(flaunch.tokenId(_memecoin));

        // Remint the tokens
        memecoin.mint(alice, 100_000_000 ether);
        deal(address(WETH), alice, 100_000_000 ether);

        vm.startPrank(alice);
        memecoin.approve(address(poolModifyPosition), type(uint).max);
        memecoin.approve(address(poolSwap), type(uint).max);
        WETH.approve(address(poolModifyPosition), type(uint).max);
        WETH.approve(address(poolSwap), type(uint).max);
        vm.stopPrank();

        // Update our PoolKey to flip
        poolKey = PoolKey({
            currency0: Currency.wrap(_flipped ? address(memecoin) : address(WETH)),
            currency1: Currency.wrap(_flipped ? address(WETH) : address(memecoin)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });

        // Update the {BidWall} reference
        bidWall = BidWall(address(positionManager.bidWall()));
        bidWall.setSwapFeeThreshold(1);

        /**
         *
         */

        // Skip the FairLaunch from taking place

        vm.startPrank(alice);

        // Perform a swap that builds fees ready to convert
        poolSwap.swap(
            poolKey,
            SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        vm.warp(block.timestamp + 1 days);

        // Perform another swap that will initialize the BidWall with the fees earned.
        // Use vm.recordLogs because the swap also emits DelegateVotesChanged from the
        // memecoin contract, which trips vm.expectEmit's strict next-emit check.
        vm.recordLogs();
        poolSwap.swap(
            poolKey,
            SwapParams({
                zeroForOne: !_flipped,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: !_flipped ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();

        _assertBidWallDepositLogged(poolKey.toId(), 0.009 ether, 0.009 ether);

        // BidWall should be initialized now
        (, bool preIsInitialized, int24 tickLower, int24 tickUpper,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(preIsInitialized, true, 'BidWall is not initialized');

        // Capture our treasury balance before closing the BidWall
        uint preETHBalance = WETH.balanceOf(memecoinTreasury);
        uint preMemecoinBalance = memecoin.balanceOf(memecoinTreasury);

        // Close our BidWall. As we are the creator of the pool we can call this directly.
        bidWall.setDisabledState(poolKey, true);

        // Capture our treasury balance after closing the BidWall
        uint postETHBalance = WETH.balanceOf(memecoinTreasury);
        uint postMemecoinBalance = memecoin.balanceOf(memecoinTreasury);

        // It should move all liquidity from the BidWall to the memecoin treasury address
        assertGt(postETHBalance, preETHBalance, 'ETH balance did not increase');
        assertGe(postMemecoinBalance, preMemecoinBalance, 'Token balance not >=');

        // Confirm that our BidWall position now has zero liquidity
        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(), owner: address(bidWall), tickLower: tickLower, tickUpper: tickUpper, salt: 'bidwall'
        });
        assertEq(liquidity, 0, 'Liquidity should be empty');

        // It should have also set the BidWall to be not initialized
        (, bool postIsInitialized,,, uint postPendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(postIsInitialized, false, 'Should not be initialised');
        assertEq(postPendingETHFees, 0, 'Should have no pending fees');

        // We should still be able to call close, even though it is no longer initialized. This
        // will just mean that no ETH is withdrawn.
        bidWall.setDisabledState(poolKey, true);
    }

    /**
     * Taking the full creator allocation leaves the BidWall with no share of future fees, so the
     * existing position must be unwound to the treasury rather than left stranded in the pool.
     */
    function test_CanCloseBidWallWhenCreatorTakesFullAllocation() external poolHasLiquidity {
        // Build up a real BidWall position through swaps
        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: true, amountSpecified: 250 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        vm.stopPrank();

        (, bool preIsInitialized, int24 tickLower, int24 tickUpper,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(preIsInitialized, true, 'BidWall should be initialized');

        uint preETHBalance = WETH.balanceOf(memecoinTreasury);

        // Hand the creator the full allocation, which should close the BidWall out
        positionManager.setCreatorFeeAllocation(address(memecoin), 100_00);

        // The BidWall liquidity should have been returned to the treasury
        assertGt(WETH.balanceOf(memecoinTreasury), preETHBalance, 'Treasury did not receive the BidWall liquidity');

        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(), owner: address(bidWall), tickLower: tickLower, tickUpper: tickUpper, salt: 'bidwall'
        });
        assertEq(liquidity, 0, 'BidWall position should be empty');

        (, bool postIsInitialized,,, uint postPendingETHFees,) = bidWall.poolInfo(poolKey.toId());
        assertEq(postIsInitialized, false, 'BidWall should no longer be initialized');
        assertEq(postPendingETHFees, 0, 'BidWall should have no pending fees');

        // The BidWall is left enabled, as the toggle is a separate dial to the allocation
        assertEq(bidWall.isBidWallEnabled(poolKey.toId()), true, 'BidWall should still be enabled');
    }

    /**
     * Re-setting the same allocation must not repeat the closure. A second `BidWallClosed` would
     * be read by consumers as a real state transition, and would burn a {PoolManager} unlock
     * against a position that has already been unwound.
     */
    function test_CannotRepeatBidWallClosureWithUnchangedAllocation() external poolHasLiquidity {
        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: true, amountSpecified: 250 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        vm.stopPrank();

        // The first call unwinds the position and legitimately reports the closure
        vm.recordLogs();
        positionManager.setCreatorFeeAllocation(address(memecoin), 100_00);
        assertEq(_countBidWallClosedLogs(poolKey.toId()), 1, 'First call should close the BidWall');

        // The second is a no-op, so it must neither close again nor re-emit
        vm.recordLogs();
        positionManager.setCreatorFeeAllocation(address(memecoin), 100_00);
        assertEq(_countBidWallClosedLogs(poolKey.toId()), 0, 'Repeat call should not close again');
    }

    function _countBidWallClosedLogs(
        PoolId _poolId
    ) internal returns (uint count_) {
        bytes32 sig = IBidWall.BidWallClosed.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bidWall) && logs[i].topics[0] == sig && logs[i].topics[1] == PoolId.unwrap(_poolId)) {
                ++count_;
            }
        }
    }

    /**
     * Lowering the allocation again should let the BidWall rebuild a position from scratch.
     *
     * The auto-close only unwinds the position; it never sets the `disabled` flag, which is
     * written solely by {setDisabledState}. The creator therefore does not need to make a
     * separate call to re-open the BidWall, and fees must not divert to the {MemecoinTreasury}
     * in the meantime.
     */
    function test_CanReopenBidWallAfterReducingCreatorAllocation() external poolHasLiquidity {
        positionManager.setCreatorFeeAllocation(address(memecoin), 100_00);

        // Closing the position must leave the BidWall enabled, otherwise the distribution would
        // route the BidWall's share to the treasury instead
        (bool disabled,,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(disabled, false, 'Auto-close should not disable the BidWall');
        assertEq(bidWall.isBidWallEnabled(poolKey.toId()), true, 'BidWall should still be enabled');

        positionManager.setCreatorFeeAllocation(address(memecoin), 0);

        uint preTreasuryBalance = WETH.balanceOf(memecoinTreasury);

        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: true, amountSpecified: 250 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        vm.stopPrank();

        // The BidWall rebuilds without any explicit re-open call
        (, bool initialized,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(initialized, true, 'BidWall should rebuild a position');

        // And the treasury received none of the BidWall's share along the way
        assertEq(WETH.balanceOf(memecoinTreasury), preTreasuryBalance, 'Treasury should not receive the BidWall share');
    }

    function test_CanInitializeTheBidWallWithASwap() external poolHasLiquidity {
        // initially the BidWall is not initialized
        (, bool preIsInitialized,,,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(preIsInitialized, false);

        // create 0.6~ in swap fees, which will pass our threshold and initialize
        vm.startPrank(alice);
        _swap(SwapParams({zeroForOne: true, amountSpecified: 250 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        vm.stopPrank();

        // It should initialize the BidWall, just below the current price
        (, bool initialized, int24 tickLower, int24 tickUpper,,) = bidWall.poolInfo(poolKey.toId());
        assertEq(initialized, true);

        (uint128 liquidity,,) = poolManager.getPositionInfo({
            poolId: poolKey.toId(), owner: address(bidWall), tickLower: tickLower, tickUpper: tickUpper, salt: 'bidwall'
        });

        // BidWall should now have sufficient liquidity
        assertGt(liquidity, 0);
    }

    function test_CanSetSwapFeeThresholdWithOwner(
        uint _newSwapFeeThreshold
    ) public {
        vm.expectEmit();
        emit IBidWall.FixedSwapFeeThresholdUpdated(_newSwapFeeThreshold);

        bidWall.setSwapFeeThreshold(_newSwapFeeThreshold);
    }

    function test_CannotSetSwapFeeThresholdWithoutOwner(
        address _caller,
        uint _newSwapFeeThreshold
    ) public {
        // Ensure the caller is not the owner
        vm.assume(_caller != address(this));

        // Expect a revert due to the onlyOwner modifier
        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        bidWall.setSwapFeeThreshold(_newSwapFeeThreshold);
        vm.stopPrank();
    }

    function test_CanTriggerStaleBidWallLiquidity() public poolHasLiquidity {
        // Provide the PoolManager with some ETH because otherwise it sulks about being poor
        // deal(address(WETH), address(poolManager), 1000e27 ether);

        // Skip the FairLaunch from taking place

        // Set a really high threshold so that our FairLaunch amount won't surpass it
        bidWall.setSwapFeeThreshold(100 ether);

        vm.startPrank(alice);

        // Perform a swap that builds fees
        poolSwap.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}));

        uint expectedFees = 0.002248410133947398 ether;

        // We will now have fees stored in the BidWall
        (,,,, uint pendingETHFees, uint cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, expectedFees, 'Invalid pendingETHFees');
        assertEq(cumulativeSwapFees, expectedFees, 'Invalid cumulativeSwapFees');

        // Move past our timeout
        vm.warp(block.timestamp + bidWall.staleTimeWindow());

        // Perform another swap that will trigger the stale liquidity to be added
        poolSwap.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}));
        vm.stopPrank();

        uint nextExpectedFees = 0.002245234892371601 ether;

        // We will now have fees stored in the BidWall, but also some fees moved into a position
        (,,,, pendingETHFees, cumulativeSwapFees) = bidWall.poolInfo(poolKey.toId());
        assertEq(pendingETHFees, nextExpectedFees, 'Invalid pendingETHFees');
        assertEq(cumulativeSwapFees, expectedFees + nextExpectedFees, 'Invalid cumulativeSwapFees');
    }

    /// @dev To run this test, comment out the Uniswap V4 Core {PoolManager} `onlyWhenUnlocked` logic
    /*
    function test_CanGetBidWallPosition() external {
        // Skip past FairLaunch
        vm.warp(block.timestamp + 365 days);

        // Get the empty position
        (uint amount0, uint amount1, uint pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(pendingEth, 0);

        // Provide sufficient tokens for the transactions
        memecoin.mint(address(this), 1 ether);
        deal(address(WETH), address(positionManager), 0.0015 ether);

        // Deposit an amount of ETH (this has to be pranked as the PositionManager for valid call). This
        // will store as pending. This is 1.5x the threshold.
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

        vm.startPrank(address(positionManager));
        WETH.approve(address(bidWall), type(uint).max);
        bidWall.depositIntoBidWall({
            _poolKey: poolKey,
            _ethSwapAmount: 0.0015 ether,
            _currentTick: tick,
            _nativeIsZero: true,
            _bypassThreshold: false
        });
        vm.stopPrank();

        // Get the position which should hold just ETH
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 1499999999999999);
        assertEq(amount1, 0);
        assertEq(pendingEth, 0);

        // Make a swap that sells some token into the BidWall position
        memecoin.approve(address(poolSwap), type(uint).max);
        _swap(
            SwapParams({
                zeroForOne: false,
                amountSpecified: -0.0025 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Get the position which should have some ETH, some token and dust fees in pending eth
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 256612490504217);
        assertEq(amount1, 2499999999999999);
        assertEq(pendingEth, 4351856283235);

        // Deposit some pending ETH below the threshold
        deal(address(WETH), address(positionManager), 0.00025 ether);

        vm.startPrank(address(positionManager));
        bidWall.depositIntoBidWall({
            _poolKey: poolKey,
            _ethSwapAmount: 0.00025 ether,
            _currentTick: tick,
            _nativeIsZero: true,
            _bypassThreshold: false
        });
        vm.stopPrank();

        // Get the position which should have some ETH, some token and some pending ETH
        (amount0, amount1, pendingEth) = bidWall.position(poolKey.toId());
        assertEq(amount0, 256612490504217);
        assertEq(amount1, 2499999999999999);
        assertEq(pendingEth, 254351856283235);
    }
    */

    // Helpers

    function _swap(
        SwapParams memory swapParams
    ) internal returns (BalanceDelta delta) {
        delta = poolSwap.swap(poolKey, swapParams);
    }

    function _assertBidWallDepositLogged(
        PoolId _poolId,
        uint _ethIn,
        uint _ethTotal
    ) internal {
        // Tolerance absorbs the small deposit variance between currency0/currency1
        // orderings; the headline ~0.009 ether deposit is what we care about.
        uint tolerance = 0.0001 ether;
        bytes32 sig = IBidWall.BidWallDeposit.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i; i < logs.length; ++i) {
            if (logs[i].emitter != address(bidWall) || logs[i].topics[0] != sig) {
                continue;
            }
            if (logs[i].topics[1] != PoolId.unwrap(_poolId)) {
                continue;
            }
            (uint loggedIn, uint loggedTotal) = abi.decode(logs[i].data, (uint, uint));
            assertApproxEqAbs(loggedIn, _ethIn, tolerance, 'BidWallDeposit ethIn mismatch');
            assertApproxEqAbs(loggedTotal, _ethTotal, tolerance, 'BidWallDeposit ethTotal mismatch');
            return;
        }
        revert('BidWallDeposit not emitted');
    }

    modifier poolHasLiquidity() {
        // Ensure that FairLaunch period has ended for the token
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1000 ether,
                salt: ''
            }),
            ''
        );
        vm.stopPrank();

        _;
    }
}
