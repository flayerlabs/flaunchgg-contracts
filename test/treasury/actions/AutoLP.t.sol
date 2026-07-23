// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from 'forge-std/Vm.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {PositionManager as V4PositionManager} from '@uniswap/v4-periphery/src/PositionManager.sol';
import {IPositionDescriptor} from '@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol';
import {IPositionManager as IV4PositionManager} from '@uniswap/v4-periphery/src/interfaces/IPositionManager.sol';
import {IWETH9} from '@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol';

import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';
import {DeployPermit2} from 'permit2/test/utils/DeployPermit2.sol';

import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {AutoLP} from '@flaunch/hooks/AutoLP.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {DeployAutoLPAction} from '@flaunch/treasury/actions/DeployAutoLP.sol';
import {UnwindAutoLPAction} from '@flaunch/treasury/actions/UnwindAutoLP.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

import {FlaunchTest} from '../../FlaunchTest.sol';
import {HookMiner} from '../../utils/HookMiner.sol';

/**
 * Integration test for the {AutoLP} hook + {DeployAutoLPAction} + {UnwindAutoLPAction} stack.
 *
 * The setUp wires up:
 *   - the standard Flaunch platform (via {FlaunchTest._deployPlatform})
 *   - a flaunch'd memecoin (so we have a real Flaunch pool with a price)
 *   - canonical Permit2 (etched at its mainnet address)
 *   - the v4-periphery {PositionManager} that mints/holds AutoLP NFTs
 *   - the {AutoLP} hook (mined at an address with the correct flag bits)
 *   - the {DeployAutoLPAction} + {UnwindAutoLPAction} actions, with the one-shot setters
 *     wired in both directions
 */
contract DeployAutoLPActionTest is FlaunchTest, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    /// Flaunch pool key + memecoin reference
    PoolKey internal flaunchPoolKey;
    address internal memecoin;

    /// AutoLP-side derived state
    PoolKey internal autoLPPoolKey;
    PoolId internal autoLPPoolId;

    /// Treasury that orchestrates the actions
    MemecoinTreasury internal memecoinTreasury;

    /// Periphery + permit2 instances
    IV4PositionManager internal v4PositionManager;
    IAllowanceTransfer internal permit2;

    /// Contracts under test
    AutoLP internal autoLPHook;
    DeployAutoLPAction internal deployAction;
    UnwindAutoLPAction internal unwindAction;

    function setUp() public {
        _deployPlatform();

        // Flaunch a memecoin so we have a real Flaunch pool with a price seeded into slot0
        memecoin = positionManager.flaunch(
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

        memecoinTreasury = MemecoinTreasury(IMemecoin(memecoin).treasury());
        flaunchPoolKey = positionManager.poolKey(memecoin);

        // Deploy canonical Permit2 + the v4-periphery PositionManager. Pass address(0) for the
        // descriptor since we never call tokenURI in these tests.
        permit2 = IAllowanceTransfer(deployPermit2());
        v4PositionManager = IV4PositionManager(
            address(new V4PositionManager(poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(flETH))))
        );

        // Mine + deploy the AutoLP hook to an address that has BEFORE_INITIALIZE_FLAG and
        // AFTER_SWAP_FLAG set in the bottom 14 bits.
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(AutoLP).creationCode, abi.encode(poolManager, address(this)));
        autoLPHook = new AutoLP{salt: salt}(poolManager, address(this));

        // Deploy our actions, wire them through the one-shot setters, and approve them
        deployAction = new DeployAutoLPAction(address(flETH), autoLPHook, v4PositionManager, permit2, oracle);
        unwindAction = new UnwindAutoLPAction(deployAction);

        autoLPHook.setTreasuryAction(address(deployAction));
        deployAction.setUnwindAction(unwindAction);

        actionManager.approveAction(address(deployAction));
        actionManager.approveAction(address(unwindAction));

        // Cache the AutoLP-side key for reuse in the asserts
        autoLPPoolKey = autoLPHook.getLPPoolKey(flaunchPoolKey);
        autoLPPoolId = autoLPPoolKey.toId();

        // Seed the treasury with both currencies so the deploy action can pull them
        deal(address(flETH), address(memecoinTreasury), 100 ether);
        deal(memecoin, address(memecoinTreasury), supplyShare(20));
    }

    /* -----------------------------------------------------------------------
     * Constructor / immutable wiring
     * --------------------------------------------------------------------- */

    function test_ConstructorState() public view {
        assertEq(Currency.unwrap(deployAction.nativeToken()), address(flETH));
        assertEq(address(deployAction.autoLPHook()), address(autoLPHook));
        assertEq(address(deployAction.v4PositionManager()), address(v4PositionManager));
        assertEq(address(deployAction.permit2()), address(permit2));
        assertEq(address(deployAction.unwindAutoLPAction()), address(unwindAction));
        assertEq(deployAction.owner(), address(this));
        assertEq(deployAction.defaultTickHalfWidth(), 600);

        assertEq(address(unwindAction.deployAction()), address(deployAction));
    }

    function test_SetUnwindAction_RevertsWhenAlreadySet() public {
        vm.expectRevert(DeployAutoLPAction.UnwindActionAlreadySet.selector);
        deployAction.setUnwindAction(UnwindAutoLPAction(address(0xBEEF)));
    }

    function test_SetUnwindAction_OnlyOwner() public {
        DeployAutoLPAction fresh = new DeployAutoLPAction(address(flETH), autoLPHook, v4PositionManager, permit2, oracle);
        vm.prank(address(0xCAFE));
        vm.expectRevert();
        fresh.setUnwindAction(unwindAction);
    }

    function test_SetDefaultTickHalfWidth_OnlyOwnerAndPositive() public {
        deployAction.setDefaultTickHalfWidth(123);
        assertEq(deployAction.defaultTickHalfWidth(), 123);

        vm.expectRevert();
        deployAction.setDefaultTickHalfWidth(0);

        vm.prank(address(0xCAFE));
        vm.expectRevert();
        deployAction.setDefaultTickHalfWidth(50);
    }

    /* -----------------------------------------------------------------------
     * execute(): caller authorization (H-1 remediation)
     * --------------------------------------------------------------------- */

    function test_Execute_RevertsForUnauthorizedCaller() public {
        // Anyone other than the canonical MemecoinTreasury must be rejected, even if they hold
        // sufficient balances and approvals. This kills the tick-range squatting attack.
        deal(address(flETH), address(0xBAD), 1 ether);
        deal(memecoin, address(0xBAD), supplyShare(1));

        vm.startPrank(address(0xBAD));
        IERC20(address(flETH)).approve(address(deployAction), type(uint).max);
        IERC20(memecoin).approve(address(deployAction), type(uint).max);
        vm.expectRevert(DeployAutoLPAction.Unauthorized.selector);
        deployAction.execute(flaunchPoolKey, abi.encode(uint(1 ether), uint(1 ether)));
        vm.stopPrank();
    }

    /* -----------------------------------------------------------------------
     * execute(): first deposit mints, subsequent deposits increase
     * --------------------------------------------------------------------- */

    function test_Execute_FirstDepositInitializesPoolAndMintsPosition() public {
        // Pre-state: AutoLP pool is uninitialized, no positions held
        (uint160 sqrtBefore,,,) = poolManager.getSlot0(autoLPPoolId);
        assertEq(sqrtBefore, 0);
        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), 0);

        uint amount0 = 1 ether;
        uint amount1 = 1 ether;

        uint expectedTokenId = v4PositionManager.nextTokenId();

        memecoinTreasury.executeAction(address(deployAction), abi.encode(amount0, amount1));

        // AutoLP pool should now be initialized from the Flaunch pool's Oracle TWAP (F-8). The
        // TWAP price is the launch-tick price snapped to the tick grid, which may differ by a
        // single tick from the raw sqrtPriceX96 that PoolManager.initialize received.
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(autoLPPoolId);
        (, int24 flaunchCurrentTick,,) = poolManager.getSlot0(flaunchPoolKey.toId());
        int24 twapTick = oracle.twapTick(flaunchPoolKey.toId(), flaunchCurrentTick);
        assertEq(sqrtAfter, TickMath.getSqrtPriceAtTick(twapTick));

        // Position state was persisted and matches the periphery NFT
        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), expectedTokenId);
        (int24 tickLower, int24 tickUpper, uint128 storedLiquidity,) = deployAction.positions(autoLPPoolId);
        assertGt(tickUpper, tickLower);
        assertGt(storedLiquidity, 0);
        assertEq(storedLiquidity, v4PositionManager.getPositionLiquidity(expectedTokenId));

        // Periphery contract holds the NFT
        assertEq(IERC721(address(v4PositionManager)).ownerOf(expectedTokenId), address(deployAction));
    }

    /**
     * F-8 regression: the AutoLP pool's seed price must come from the Flaunch pool's Oracle TWAP,
     * NOT its raw slot0. Previously the seeder read `pm.getSlot0(_flaunchPoolKey.toId())` which
     * is manipulable by an atomic swap inside the same transaction. With the fix in place a
     * spot-skewing swap immediately before the first deposit should NOT change the AutoLP
     * opening price (the TWAP averages over the launch-tick observation seeded by F-7).
     */
    function test_F8_AutoLPSeedFromTwapIgnoresManipulatedSpot() public {
        // Skew the Flaunch pool's spot price away from the launch tick by buying memecoin with
        // a sizeable native amount. This pushes slot0 far from the original launch sqrtPriceX96.
        bool nativeIsZero = Currency.unwrap(flaunchPoolKey.currency0) == address(flETH);
        _swap(flaunchPoolKey, nativeIsZero, 10 ether);

        (uint160 skewedSpot, int24 skewedTick,,) = poolManager.getSlot0(flaunchPoolKey.toId());

        // The TWAP, with only the launch-tick observation seeded by F-7, must clamp the window
        // to the time elapsed and reflect the historical launch tick (or fall back gracefully).
        int24 expectedTwapTick = oracle.twapTick(flaunchPoolKey.toId(), skewedTick);
        uint160 expectedSeedSqrtPriceX96 = TickMath.getSqrtPriceAtTick(expectedTwapTick);

        // Execute the action; this triggers `_initializeIfNeeded` against the AutoLP pool
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        // The AutoLP pool must be seeded from the TWAP, not from the manipulated spot.
        (uint160 autoLPSqrt,,,) = poolManager.getSlot0(autoLPPoolId);
        assertEq(autoLPSqrt, expectedSeedSqrtPriceX96, 'AutoLP seeded from TWAP');
        assertTrue(autoLPSqrt != skewedSpot, 'AutoLP must not match skewed spot');
    }

    function test_Execute_SecondDepositIncreasesExistingPosition() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));
        uint tokenId = deployAction.poolPositionTokenId(autoLPPoolId);
        uint128 liqAfterFirst = v4PositionManager.getPositionLiquidity(tokenId);

        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(0.5 ether), uint(0.5 ether)));

        // Same tokenId is reused, liquidity has grown
        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), tokenId);
        uint128 liqAfterSecond = v4PositionManager.getPositionLiquidity(tokenId);
        assertGt(liqAfterSecond, liqAfterFirst);
    }

    function test_Execute_ZeroDepositIsNoOp() public {
        // Calling with (0,0) doesn't mint a position, doesn't pull anything, but still
        // initializes the AutoLP pool and emits the event with zero deltas.
        vm.expectEmit();
        emit ITreasuryAction.ActionExecuted(flaunchPoolKey, 0, 0);
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(0), uint(0)));

        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), 0);

        (uint160 sqrtAfter,,,) = poolManager.getSlot0(autoLPPoolId);
        assertGt(sqrtAfter, 0);
    }

    /* -----------------------------------------------------------------------
     * No-stranded-funds invariant — execute() refunds unused deposit and
     * _compoundFees() sweeps any memecoin dust to the cached treasury, so the
     * action's per-currency balance never grows as a side effect of a call.
     * --------------------------------------------------------------------- */

    function test_Execute_DoesNotStrandTokensOnTheAction_HappyPath() public {
        // First call mints. After it returns, the action contract's per-currency balance
        // attributable to this pool must be zero — any dust from rounding has been refunded
        // back to the calling treasury and any compound fees would have been forwarded to
        // the cached treasury.
        uint actionPre0 = autoLPPoolKey.currency0.balanceOf(address(deployAction));
        uint actionPre1 = autoLPPoolKey.currency1.balanceOf(address(deployAction));

        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        assertEq(autoLPPoolKey.currency0.balanceOf(address(deployAction)), actionPre0);
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionPre1);

        // Second call increases. Same invariant: no growth on the action contract.
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        assertEq(autoLPPoolKey.currency0.balanceOf(address(deployAction)), actionPre0);
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionPre1);
    }

    function test_Execute_RefundsFullDepositWhenLiquidityIsZero() public {
        // Stand up a position so `_resolveLiquidityAndRange` uses the existing stored range
        // rather than recomputing one. The range is centered on the current AutoLP price.
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        // Push the AutoLP pool's price ABOVE the upper tick of the stored range by swapping a
        // large amount of currency1 in (zeroForOne = false drives the price up).
        (, int24 tickUpper,,) = deployAction.positions(autoLPPoolId);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        _swap(autoLPPoolKey, false, 50 ether);

        (uint160 sqrtAfter,,,) = poolManager.getSlot0(autoLPPoolId);
        require(sqrtAfter >= sqrtUpper, 'precondition: price not above upper');

        // Now a single-sided currency0 deposit on this pool's stored range yields zero liquidity
        // (`_sqrt >= _sqrtUpper` -> `_liquidityFromAmounts` returns 0). Pre-fix: the entire
        // amount0 would have been silently stranded on the action. Post-fix: it must be refunded
        // back to the treasury, with the action's per-currency balance left unchanged.
        uint treasuryPre0 = autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury));
        uint actionPre0 = autoLPPoolKey.currency0.balanceOf(address(deployAction));
        uint actionPre1 = autoLPPoolKey.currency1.balanceOf(address(deployAction));

        uint depositAmount = 1 ether;
        memecoinTreasury.executeAction(address(deployAction), abi.encode(depositAmount, uint(0)));

        // Treasury's currency0 balance is unchanged: it pulled `depositAmount` and got the same
        // amount refunded.
        assertEq(autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury)), treasuryPre0);
        // Action contract's per-currency balances are unchanged: nothing stranded.
        assertEq(autoLPPoolKey.currency0.balanceOf(address(deployAction)), actionPre0);
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionPre1);
    }

    function test_Execute_DoesNotTouchOtherPoolBalancesOnTheAction() public {
        // Simulate a *different* pool's funds that have arrived on the action contract (e.g. from
        // some other pool's `_compoundFees` having cached a transient balance, or from a manual
        // top-up). The action's `execute` must NEVER include these in any refund/sweep — refunds
        // are computed strictly in delta-space against a snapshot taken before the pull.
        uint foreignFlETH = 12345;
        uint foreignMemecoin = 67890;
        deal(address(flETH), address(deployAction), foreignFlETH);
        deal(memecoin, address(deployAction), foreignMemecoin);

        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        // Foreign balances are still parked on the action — execute didn't touch them.
        assertEq(IERC20(address(flETH)).balanceOf(address(deployAction)), foreignFlETH);
        assertEq(IERC20(memecoin).balanceOf(address(deployAction)), foreignMemecoin);
    }

    /* -----------------------------------------------------------------------
     * compoundFees() — public/permissionless path
     * --------------------------------------------------------------------- */

    function test_CompoundFees_NoPositionIsNoOp() public {
        // No position has been minted yet → noop, no balance changes
        deployAction.compoundFees(autoLPPoolKey);
        assertEq(autoLPPoolKey.currency0.balanceOf(address(deployAction)), 0);
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), 0);
    }

    function test_CompoundFees_NativeLegForwardsToTreasury() public {
        // Mint a position with both sides
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        // Snapshot pre-swap balances on both the treasury and the action so we can isolate the
        // fee leg (the action carries unused dust from the initial seed).
        uint treasuryNativeBefore = autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury));
        uint actionNativeBefore = autoLPPoolKey.currency0.balanceOf(address(deployAction));
        uint actionMemecoinBefore = autoLPPoolKey.currency1.balanceOf(address(deployAction));

        // Swap zeroForOne (native -> memecoin) to generate fees on the native (currency0) leg
        _swap(autoLPPoolKey, true, 0.5 ether);

        // afterSwap will have fired; native fees forwarded to the memecoin treasury
        assertGt(autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury)), treasuryNativeBefore);

        // Action's balances haven't grown — fees were collected and immediately forwarded
        assertEq(autoLPPoolKey.currency0.balanceOf(address(deployAction)), actionNativeBefore);
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionMemecoinBefore);
    }

    function test_CompoundFees_MemecoinLegRedepositsIntoPosition() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));
        uint tokenId = deployAction.poolPositionTokenId(autoLPPoolId);
        uint128 liquidityBeforeSwap = v4PositionManager.getPositionLiquidity(tokenId);

        // Swap oneForZero (memecoin -> native) to generate fees on the memecoin (currency1) leg
        _swap(autoLPPoolKey, false, supplyShare(1));

        // Position liquidity has grown because the memecoin fees were re-deposited
        uint128 liquidityAfter = v4PositionManager.getPositionLiquidity(tokenId);
        assertGt(liquidityAfter, liquidityBeforeSwap);

        (,, uint128 storedLiquidity,) = deployAction.positions(autoLPPoolId);
        assertEq(storedLiquidity, liquidityAfter);
    }

    function test_CompoundFees_ExternalCallAfterRebaseIsSafe() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));
        _swap(autoLPPoolKey, true, 0.5 ether);

        // Calling externally after the auto-compound is a clean no-op (no fees left)
        uint treasuryBefore = autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury));
        deployAction.compoundFees(autoLPPoolKey);
        assertEq(autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury)), treasuryBefore);
    }

    /* -----------------------------------------------------------------------
     * unwind() — only the wired-in unwind action may call
     * --------------------------------------------------------------------- */

    function test_Unwind_RevertsForNonAuthorisedCaller() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        vm.expectRevert(DeployAutoLPAction.Unauthorized.selector);
        deployAction.unwind(autoLPPoolKey, address(this), 0, 0);
    }

    function test_Unwind_RevertsIfNoPosition() public {
        vm.prank(address(unwindAction));
        vm.expectRevert(DeployAutoLPAction.InvalidTokenId.selector);
        deployAction.unwind(autoLPPoolKey, address(this), 0, 0);
    }

    function test_Unwind_FullyClosesPositionAndForwardsFunds() public {
        // Stand up a position first
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));
        uint tokenId = deployAction.poolPositionTokenId(autoLPPoolId);
        assertGt(tokenId, 0);

        uint treasuryBefore0 = autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury));
        uint treasuryBefore1 = autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury));

        // Treasury triggers the unwind action; freed funds should be forwarded back to it
        memecoinTreasury.executeAction(address(unwindAction), '');

        // Local state has been wiped
        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), 0);
        (int24 tickLower, int24 tickUpper, uint128 storedLiquidity, address treasuryCache) = deployAction.positions(autoLPPoolId);
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(storedLiquidity, 0);
        assertEq(treasuryCache, address(0));

        // The periphery NFT now shows zero liquidity (DECREASE_LIQUIDITY by full liquidity)
        assertEq(v4PositionManager.getPositionLiquidity(tokenId), 0);

        // The treasury received at least some of the freed currencies back
        uint received0 = autoLPPoolKey.currency0.balanceOf(address(memecoinTreasury)) - treasuryBefore0;
        uint received1 = autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury)) - treasuryBefore1;
        assertGt(received0 + received1, 0);
    }

    /* -----------------------------------------------------------------------
     * recoverPositionNFT() — owner escape hatch (now treasury-pinned)
     * --------------------------------------------------------------------- */

    function test_RecoverPositionNFT_OnlyOwner() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        vm.prank(address(0xCAFE));
        vm.expectRevert();
        deployAction.recoverPositionNFT(autoLPPoolId);
    }

    function test_RecoverPositionNFT_RevertsIfNoPosition() public {
        vm.expectRevert(DeployAutoLPAction.InvalidTokenId.selector);
        deployAction.recoverPositionNFT(autoLPPoolId);
    }

    function test_RecoverPositionNFT_AlwaysSendsToOwner() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));
        uint tokenId = deployAction.poolPositionTokenId(autoLPPoolId);

        // Owner cannot redirect: the recover function has no caller-supplied recipient and the
        // NFT is always sent to `owner()` — the operational multisig that wired the action up
        // and is the only party able to manage the position off-action.
        deployAction.recoverPositionNFT(autoLPPoolId);

        assertEq(IERC721(address(v4PositionManager)).ownerOf(tokenId), deployAction.owner());
        assertEq(deployAction.poolPositionTokenId(autoLPPoolId), 0);
        (int24 tickLower, int24 tickUpper, uint128 storedLiquidity, address treasuryCache) = deployAction.positions(autoLPPoolId);
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(storedLiquidity, 0);
        assertEq(treasuryCache, address(0));
    }

    /* -----------------------------------------------------------------------
     * UnwindAutoLPAction — wrapper passthrough
     * --------------------------------------------------------------------- */

    function test_UnwindAction_RevertsIfNoPosition() public {
        // No position has been minted → nested unwind reverts with InvalidTokenId
        vm.expectRevert(DeployAutoLPAction.InvalidTokenId.selector);
        memecoinTreasury.executeAction(address(unwindAction), '');
    }

    function test_UnwindAction_DirectExecute_RevertsForUnauthorizedCaller() public {
        // Stand up a position so there's something to drain
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));
        assertGt(deployAction.poolPositionTokenId(autoLPPoolId), 0);

        // Anyone other than the canonical MemecoinTreasury must be rejected when calling
        // execute() directly. This closes the F-1 unwind-recipient hijack: without this
        // gate, an arbitrary EOA could call unwindAction.execute(victimKey, "") and have
        // the freed AutoLP currencies forwarded to themselves.
        vm.prank(address(0xBAD));
        vm.expectRevert(UnwindAutoLPAction.Unauthorized.selector);
        unwindAction.execute(flaunchPoolKey, '');

        // Position is still live and untouched
        assertGt(deployAction.poolPositionTokenId(autoLPPoolId), 0);
    }

    function test_UnwindAction_RespectsSlippageMinimums() public {
        // Stand up a position
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        // Forward an unrealistically high min0/min1 through the wrapper. The periphery's
        // DECREASE_LIQUIDITY action will reject the unwind, protecting the treasury from
        // sandwich-induced bad-composition extractions.
        bytes memory payload = abi.encode(uint128(type(uint128).max), uint128(type(uint128).max));
        vm.expectRevert();
        memecoinTreasury.executeAction(address(unwindAction), payload);

        // Position is still live
        assertGt(deployAction.poolPositionTokenId(autoLPPoolId), 0);
    }

    /* -----------------------------------------------------------------------
     * Cached treasury (M-2 remediation)
     * --------------------------------------------------------------------- */

    function test_CompoundFees_CachesTreasuryAtFirstExecute() public {
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));
        (,,, address treasuryCache) = deployAction.positions(autoLPPoolId);
        assertEq(treasuryCache, address(memecoinTreasury));
    }

    /* -----------------------------------------------------------------------
     * Tick math is overflow-safe for boundary tick centers (M-3 remediation)
     * --------------------------------------------------------------------- */

    function test_RecommendTickRange_TolerantOfHugeHalfWidth() public {
        // Crank the half-width well above any sane value. With the int256-widened arithmetic
        // and clamp-first ordering, _recommendTickRange must not revert; it should simply pin
        // to the usable tick boundaries and still mint a valid position.
        deployAction.setDefaultTickHalfWidth(type(int24).max - 1);

        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        (int24 tickLower, int24 tickUpper,,) = deployAction.positions(autoLPPoolId);
        assertLt(tickLower, tickUpper);
        assertGt(deployAction.poolPositionTokenId(autoLPPoolId), 0);
    }

    /* -----------------------------------------------------------------------
     * Permit2 approvals are set lazily on first execute()
     * --------------------------------------------------------------------- */

    /* -----------------------------------------------------------------------
     * F-11 — in-range single-sided memecoin re-deposit must not revert
     * --------------------------------------------------------------------- */

    /**
     * F-11 regression (execute path). A single-sided memecoin (currency1) deposit into a stored
     * range that STRADDLES the current price used to compute non-zero liquidity via
     * `_liquidityFromAmounts`, so `_increasePosition` encoded `amount0Max = 0` on the empty native
     * side and the periphery's `SlippageCheck.validateMaxIn` reverted the whole call.
     *
     * With the fix `_liquidityFromAmounts` returns 0 when the range straddles the price, so
     * `_increasePosition` no-ops and `execute` refunds the untouched deposit to the treasury
     * instead of reverting.
     */
    function test_F11_InRangeSingleSidedMemecoinDepositRefundsInsteadOfReverting() public {
        // In this fixture native flETH is currency0, so the memecoin is currency1.
        assertEq(Currency.unwrap(autoLPPoolKey.currency0), address(flETH), 'expected native as currency0');

        // Mint a centered position; its range straddles the current price by construction.
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        (int24 tickLower, int24 tickUpper, uint128 liquidityBefore,) = deployAction.positions(autoLPPoolId);
        (, int24 currentTick,,) = poolManager.getSlot0(autoLPPoolId);
        assertTrue(tickLower < currentTick && currentTick < tickUpper, 'range must straddle the price');

        uint treasuryMemeBefore = autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury));
        uint actionMemeBefore = autoLPPoolKey.currency1.balanceOf(address(deployAction));

        // Single-sided memecoin (currency1) deposit into the in-range range. Pre-fix: reverts.
        // Post-fix: no-op + full refund back to the treasury.
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(0), uint(1 ether)));

        // Deposit fully refunded (nothing consumed), nothing stranded, position untouched.
        assertEq(autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury)), treasuryMemeBefore, 'deposit not refunded');
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionMemeBefore, 'memecoin stranded on action');
        (,, uint128 liquidityAfter,) = deployAction.positions(autoLPPoolId);
        assertEq(liquidityAfter, liquidityBefore, 'position liquidity must be unchanged');
    }

    /**
     * F-11 regression (compound path — the literal finding scenario). A small in-range
     * `oneForZero` sell charges memecoin-only (currency1) LP fees. The AutoLP hook's `afterSwap`
     * auto-compound then re-deposits that memecoin leg single-sided into an in-range range.
     *
     * Pre-fix this reverted inside `_increasePosition` and was swallowed as `CompoundFailed`,
     * which also rolled back the native-leg forward. Post-fix the compound does not revert, no
     * `CompoundFailed` is emitted, and the memecoin-leg fee is swept through to the treasury.
     */
    function test_F11_InRangeMemecoinCompoundForwardsToTreasuryNotCompoundFailed() public {
        // Full-range position: the range always straddles the price, so any memecoin swap keeps us
        // on the fixed straddle branch of `_liquidityFromAmounts`.
        deployAction.setDefaultTickHalfWidth(type(int24).max - 1);
        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(2 ether), uint(2 ether)));

        (int24 tickLower, int24 tickUpper,,) = deployAction.positions(autoLPPoolId);
        (, int24 currentTick,,) = poolManager.getSlot0(autoLPPoolId);
        assertTrue(tickLower < currentTick && currentTick < tickUpper, 'range must straddle the price');

        uint treasuryMemeBefore = autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury));
        uint actionMemeBefore = autoLPPoolKey.currency1.balanceOf(address(deployAction));

        // oneForZero (memecoin -> native) charges memecoin-only fees; afterSwap fires the compound.
        vm.recordLogs();
        _swap(autoLPPoolKey, false, supplyShare(1));
        _assertNoCompoundFailed();

        // Full range can never be exited, so the compound stayed on the straddle branch.
        (, int24 tickAfter,,) = poolManager.getSlot0(autoLPPoolId);
        assertTrue(tickLower < tickAfter && tickAfter < tickUpper, 'range must still straddle the price');

        // Memecoin-leg fee was forwarded to the treasury, not stranded on the action or lost.
        assertGt(
            autoLPPoolKey.currency1.balanceOf(address(memecoinTreasury)), treasuryMemeBefore, 'memecoin fee not forwarded to treasury'
        );
        assertEq(autoLPPoolKey.currency1.balanceOf(address(deployAction)), actionMemeBefore, 'memecoin stranded on action');

        // The un-swallowed public compound path is clean too (nothing left, no revert).
        deployAction.compoundFees(autoLPPoolKey);
    }

    /// Fails if the AutoLP hook emitted `CompoundFailed` (i.e. the auto-compound reverted).
    function _assertNoCompoundFailed() internal {
        bytes32 topic = keccak256('CompoundFailed(bytes32,bytes)');
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i; i < logs.length; ++i) {
            if (logs[i].emitter == address(autoLPHook) && logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                revert('CompoundFailed emitted: in-range memecoin compound reverted');
            }
        }
    }

    /* -----------------------------------------------------------------------
     * Helpers
     * --------------------------------------------------------------------- */

    /**
     * Performs a swap on the supplied pool through the test {PoolSwap} zap, dealing the input
     * currency to this contract first and approving the zap. Triggers the AutoLP hook's
     * `afterSwap` callback when run against the AutoLP pool.
     */
    function _swap(
        PoolKey memory _poolKey,
        bool _zeroForOne,
        uint _amountIn
    ) internal {
        Currency input = _zeroForOne ? _poolKey.currency0 : _poolKey.currency1;
        deal(Currency.unwrap(input), address(this), _amountIn);
        IERC20(Currency.unwrap(input)).approve(address(poolSwap), _amountIn);

        poolSwap.swap(
            _poolKey,
            SwapParams({
                zeroForOne: _zeroForOne,
                amountSpecified: -int(_amountIn),
                sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function test_PermitApprovalsSetOnExecute() public {
        // Pre-execute: no allowances
        (uint160 amt, uint48 exp,) =
            permit2.allowance(address(deployAction), Currency.unwrap(autoLPPoolKey.currency0), address(v4PositionManager));
        assertEq(amt, 0);
        assertEq(exp, 0);

        memecoinTreasury.executeAction(address(deployAction), abi.encode(uint(1 ether), uint(1 ether)));

        (amt, exp,) = permit2.allowance(address(deployAction), Currency.unwrap(autoLPPoolKey.currency0), address(v4PositionManager));
        assertEq(amt, type(uint160).max);
        assertEq(exp, type(uint48).max);

        (amt, exp,) = permit2.allowance(address(deployAction), Currency.unwrap(autoLPPoolKey.currency1), address(v4PositionManager));
        assertEq(amt, type(uint160).max);
        assertEq(exp, type(uint48).max);
    }
}
