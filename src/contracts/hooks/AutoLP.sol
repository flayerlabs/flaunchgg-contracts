// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {BaseHook} from '@uniswap-hooks/base/BaseHook.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {IDeployAutoLPAction} from '@flaunch-interfaces/IDeployAutoLPAction.sol';

/**
 * Treasury-owned AutoLP hook.
 *
 * Acts as a thin gate for a dedicated AutoLP pool that mirrors the underlying Flaunch pool but
 * lives at a separate fee tier. Two responsibilities:
 *
 *   1. Restrict pool initialization so only the wired-in treasury action can spin up the AutoLP
 *      pool with a price seeded from the Flaunch pool.
 *   2. Trigger automatic compounding of accrued LP fees after every swap by calling back into
 *      the treasury action. Compound failures are swallowed so a misbehaving treasury can never
 *      brick the AutoLP pool's swap path.
 *
 * The hook stores no liquidity itself; the treasury action owns the position NFT.
 */
contract AutoLP is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    error NotAllowed();
    error TreasuryActionAlreadySet();

    /**
     * @notice Emitted when the post-swap call to `treasuryAction.compoundFees` reverts. The
     *         swap itself is allowed to proceed regardless so the AutoLP pool stays usable.
     *
     * @param poolId The AutoLP poolId whose compound failed
     * @param reason The raw revert data from the failed call
     */
    event CompoundFailed(PoolId indexed poolId, bytes reason);

    /// @notice Fee tier (in pips) used for the dedicated AutoLP pool (1.00%)
    uint24 public constant AUTO_LP_FEE = 10_000;

    /// @notice Treasury action that owns and manages the AutoLP positions
    IDeployAutoLPAction public treasuryAction;

    /**
     * @param _manager The Uniswap v4 PoolManager
     * @param _owner The address that may set the treasury action once after deployment
     */
    constructor(
        IPoolManager _manager,
        address _owner
    ) BaseHook(_manager) {
        _initializeOwner(_owner);
    }

    /**
     * One-shot setter that wires the treasury action into the hook. Must be called once before
     * the hook becomes useful and cannot be re-pointed afterwards.
     *
     * @param _treasuryAction The {DeployAutoLPAction} that will own AutoLP positions
     */
    function setTreasuryAction(
        address _treasuryAction
    ) external onlyOwner {
        if (address(treasuryAction) != address(0)) {
            revert TreasuryActionAlreadySet();
        }
        treasuryAction = IDeployAutoLPAction(_treasuryAction);
    }

    /**
     * Declares enabled hook callbacks for this contract.
     *
     * @return The permissions for the hook
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * Builds the AutoLP {PoolKey} that mirrors the supplied Flaunch pool but at the dedicated
     * AutoLP fee tier and routed through this hook.
     *
     * @param _flaunchPoolKey The Flaunch {PoolKey}
     */
    function getLPPoolKey(
        PoolKey memory _flaunchPoolKey
    ) public view returns (PoolKey memory autoLPPoolKey_) {
        autoLPPoolKey_ = PoolKey({
            currency0: _flaunchPoolKey.currency0,
            currency1: _flaunchPoolKey.currency1,
            fee: AUTO_LP_FEE,
            tickSpacing: _flaunchPoolKey.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /**
     * Initializes the AutoLP pool. Only the wired-in treasury action may call this; the hook
     * is the only address allowed to call `poolManager.initialize` for the AutoLP key (enforced
     * by `_beforeInitialize`).
     *
     * @dev Reverts (via the underlying `poolManager.initialize`) if the AutoLP pool has already
     *      been initialized. The treasury action's `_initializeIfNeeded` gates on slot0 to avoid
     *      ever taking that path in normal operation.
     *
     * @param _flaunchPoolKey The Flaunch {PoolKey} the AutoLP pool will mirror
     * @param _sqrtPriceX96 The initial sqrt price for the AutoLP pool
     */
    function initializePool(
        PoolKey memory _flaunchPoolKey,
        uint160 _sqrtPriceX96
    ) external returns (int24 tick_) {
        // Only the treasury action can initialize the pool
        if (msg.sender != address(treasuryAction)) {
            revert NotAllowed();
        }

        // Initialize the pool on Uniswap V4
        tick_ = poolManager.initialize(getLPPoolKey(_flaunchPoolKey), _sqrtPriceX96);
    }

    /**
     * Restricts initialization of any pool that hooks into this contract to the hook itself,
     * which means it can only happen via `initializePool` above. This prevents anyone front-running
     * us with an unfavourable starting price.
     *
     * @param _sender The original caller of `poolManager.initialize`
     */
    function _beforeInitialize(
        address _sender,
        PoolKey calldata,
        uint160
    ) internal view override returns (bytes4) {
        if (_sender != address(this)) {
            revert NotAllowed();
        }
        return this.beforeInitialize.selector;
    }

    /**
     * After every swap on the AutoLP pool, asks the treasury action to collect and compound
     * accrued fees. The action detects the unlocked PoolManager and uses the periphery
     * PositionManager's `modifyLiquiditiesWithoutUnlock` path so we don't try to re-unlock.
     *
     * The call is wrapped in `try/catch` because a misbehaving treasury (e.g. a paused fee
     * recipient, an upgrade-bricked memecoin proxy, a periphery revert on settlement) must not
     * be allowed to take down the AutoLP pool's swap path. The revert reason is surfaced
     * verbatim through the {CompoundFailed} event for off-chain monitoring.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey} that was just swapped against
     */
    function _afterSwap(
        address,
        PoolKey calldata _autoLPPoolKey,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        IDeployAutoLPAction action = treasuryAction;
        if (address(action) != address(0)) {
            try action.compoundFees(_autoLPPoolKey) {}
            catch (bytes memory reason) {
                emit CompoundFailed(_autoLPPoolKey.toId(), reason);
            }
        }

        return (this.afterSwap.selector, 0);
    }
}
