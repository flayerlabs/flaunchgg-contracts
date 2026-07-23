// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from 'forge-std/Vm.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BalanceDelta, BalanceDeltaLibrary} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {AutoLP} from '@flaunch/hooks/AutoLP.sol';

import {IDeployAutoLPAction} from '@flaunch-interfaces/IDeployAutoLPAction.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {HookMiner} from '../utils/HookMiner.sol';

/**
 * Mock treasury action that records every {compoundFees} call so the hook tests can assert on
 * downstream invocation behaviour without spinning up the real periphery PositionManager stack.
 */
contract MockTreasuryAction is IDeployAutoLPAction {
    PoolKey public lastPoolKey;
    uint public callCount;

    function compoundFees(
        PoolKey memory _autoLPPoolKey
    ) external override {
        lastPoolKey = _autoLPPoolKey;
        ++callCount;
    }
}

/**
 * Mock treasury action that always reverts. Used to verify that the hook swallows compound
 * failures (H-2) and lets the swap proceed regardless.
 */
contract RevertingMockTreasuryAction is IDeployAutoLPAction {
    error AlwaysReverts();

    function compoundFees(
        PoolKey memory
    ) external pure override {
        revert AlwaysReverts();
    }
}

/**
 * Unit tests for the {AutoLP} hook in isolation. We use a {MockTreasuryAction} so the tests can
 * focus on the hook's gating + callback wiring without depending on the v4-periphery
 * PositionManager.
 */
contract AutoLPHookTest is FlaunchTest {
    /// AutoLP hook + downstream mock action under test
    AutoLP internal autoLPHook;
    MockTreasuryAction internal mockAction;

    /// A representative Flaunch poolKey used to derive the AutoLP pool
    PoolKey internal flaunchPoolKey;

    function setUp() public {
        _deployPlatform();

        // Mine + deploy the AutoLP hook to an address with the right flag bits
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(AutoLP).creationCode, abi.encode(poolManager, address(this)));
        autoLPHook = new AutoLP{salt: salt}(poolManager, address(this));

        mockAction = new MockTreasuryAction();

        flaunchPoolKey = PoolKey({
            currency0: Currency.wrap(address(0xA)),
            currency1: Currency.wrap(address(0xB)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(positionManager))
        });
    }

    /* -----------------------------------------------------------------------
     * Constructor + immutable state
     * --------------------------------------------------------------------- */

    function test_Constructor_SetsOwnerAndPoolManager() public view {
        assertEq(autoLPHook.owner(), address(this));
        assertEq(address(autoLPHook.poolManager()), address(poolManager));
        assertEq(address(autoLPHook.treasuryAction()), address(0));
        assertEq(autoLPHook.AUTO_LP_FEE(), 10_000);
    }

    function test_GetHookPermissions() public view {
        Hooks.Permissions memory perms = autoLPHook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.afterSwap);

        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    /* -----------------------------------------------------------------------
     * setTreasuryAction — owner-gated, one-shot
     * --------------------------------------------------------------------- */

    function test_SetTreasuryAction_OnlyOwner() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert();
        autoLPHook.setTreasuryAction(address(mockAction));
    }

    function test_SetTreasuryAction_HappyPath() public {
        autoLPHook.setTreasuryAction(address(mockAction));
        assertEq(address(autoLPHook.treasuryAction()), address(mockAction));
    }

    function test_SetTreasuryAction_OneShot() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        vm.expectRevert(AutoLP.TreasuryActionAlreadySet.selector);
        autoLPHook.setTreasuryAction(address(0xCAFE));
    }

    /* -----------------------------------------------------------------------
     * getLPPoolKey — pure key derivation
     * --------------------------------------------------------------------- */

    function test_GetLPPoolKey_OverridesFeeAndHook() public view {
        PoolKey memory autoLP = autoLPHook.getLPPoolKey(flaunchPoolKey);

        // Currencies + tick spacing are inherited
        assertEq(Currency.unwrap(autoLP.currency0), Currency.unwrap(flaunchPoolKey.currency0));
        assertEq(Currency.unwrap(autoLP.currency1), Currency.unwrap(flaunchPoolKey.currency1));
        assertEq(autoLP.tickSpacing, flaunchPoolKey.tickSpacing);

        // Fee + hook are pinned to the AutoLP defaults
        assertEq(autoLP.fee, autoLPHook.AUTO_LP_FEE());
        assertEq(address(autoLP.hooks), address(autoLPHook));
    }

    /* -----------------------------------------------------------------------
     * initializePool — gated to the wired-in treasury action
     * --------------------------------------------------------------------- */

    function test_InitializePool_RevertsIfTreasuryActionUnset() public {
        // treasuryAction defaults to address(0); any non-zero caller fails
        vm.expectRevert(AutoLP.NotAllowed.selector);
        autoLPHook.initializePool(flaunchPoolKey, 79228162514264337593543950336);
    }

    function test_InitializePool_RevertsForNonTreasuryActionCaller() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        vm.prank(address(0xBEEF));
        vm.expectRevert(AutoLP.NotAllowed.selector);
        autoLPHook.initializePool(flaunchPoolKey, 79228162514264337593543950336);
    }

    function test_InitializePool_TreasuryActionCanInit() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        // The mock action is allowed to call. The hook routes the call through
        // poolManager.initialize, returning a valid tick on success.
        vm.prank(address(mockAction));
        int24 tick = autoLPHook.initializePool(flaunchPoolKey, 79228162514264337593543950336);
        assertEq(tick, 0);
    }

    function test_InitializePool_AlreadyInitializedReverts() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        vm.prank(address(mockAction));
        autoLPHook.initializePool(flaunchPoolKey, 79228162514264337593543950336);

        // Second call must revert: we deliberately do NOT silently swallow the duplicate init
        // here. The treasury action's `_initializeIfNeeded` is the one place that checks slot0
        // before calling, so this path is unreachable in normal operation.
        vm.prank(address(mockAction));
        vm.expectRevert();
        autoLPHook.initializePool(flaunchPoolKey, 79228162514264337593543950336);
    }

    /* -----------------------------------------------------------------------
     * beforeInitialize — only the hook itself may call poolManager.initialize
     *                    on a key that hooks into this contract
     * --------------------------------------------------------------------- */

    function test_BeforeInitialize_RevertsForExternalSender() public {
        // Build a key where the hook is this AutoLP instance
        PoolKey memory hookedKey = PoolKey({
            currency0: Currency.wrap(address(0xA)),
            currency1: Currency.wrap(address(0xB)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(autoLPHook))
        });

        // Direct call into PoolManager from this test contract → caller is not the hook → revert
        vm.expectRevert();
        poolManager.initialize(hookedKey, 79228162514264337593543950336);
    }

    /* -----------------------------------------------------------------------
     * afterSwap — must only be invoked by the PoolManager
     * --------------------------------------------------------------------- */

    function test_AfterSwap_RevertsIfCalledOutsideOfPoolManager() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.expectRevert();
        autoLPHook.afterSwap(address(this), flaunchPoolKey, params, BalanceDeltaLibrary.ZERO_DELTA, '');
    }

    function test_AfterSwap_NoOpIfTreasuryActionUnset() public {
        // Calling from the PoolManager context, but with no treasury action set, should not revert
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        autoLPHook.afterSwap(address(this), flaunchPoolKey, params, BalanceDeltaLibrary.ZERO_DELTA, '');

        assertEq(mockAction.callCount(), 0);
    }

    function test_AfterSwap_SwallowsRevertingCompoundAndEmitsEvent() public {
        // Wire in a reverting mock so any compound attempt unconditionally fails. The hook must
        // catch the revert, emit CompoundFailed, and still return cleanly so the swap proceeds.
        RevertingMockTreasuryAction reverting = new RevertingMockTreasuryAction();
        autoLPHook.setTreasuryAction(address(reverting));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        // We don't pin on the exact reason bytes — just that the event fires for this poolId.
        vm.recordLogs();
        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            autoLPHook.afterSwap(address(this), flaunchPoolKey, params, BalanceDeltaLibrary.ZERO_DELTA, '');

        assertEq(selector, autoLPHook.afterSwap.selector);
        assertEq(hookDelta, int128(0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256('CompoundFailed(bytes32,bytes)');
        bool found;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                found = true;
                break;
            }
        }
        assertTrue(found, 'CompoundFailed event not emitted');
    }

    function test_AfterSwap_ForwardsCompoundCallToTreasuryAction() public {
        autoLPHook.setTreasuryAction(address(mockAction));

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.prank(address(poolManager));
        (bytes4 selector, int128 hookDelta) =
            autoLPHook.afterSwap(address(this), flaunchPoolKey, params, BalanceDeltaLibrary.ZERO_DELTA, '');

        // Selector + zero delta returned per BaseHook contract
        assertEq(selector, autoLPHook.afterSwap.selector);
        assertEq(hookDelta, int128(0));

        // Mock action received exactly one compound call with the same key the hook saw
        assertEq(mockAction.callCount(), 1);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing,) = mockAction.lastPoolKey();
        assertEq(Currency.unwrap(c0), Currency.unwrap(flaunchPoolKey.currency0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(flaunchPoolKey.currency1));
        assertEq(fee, flaunchPoolKey.fee);
        assertEq(tickSpacing, flaunchPoolKey.tickSpacing);
    }
}
