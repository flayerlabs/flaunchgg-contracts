// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {TransientStateLibrary} from '@uniswap/v4-core/src/libraries/TransientStateLibrary.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {IPositionManager} from '@uniswap/v4-periphery/src/interfaces/IPositionManager.sol';
import {Actions} from '@uniswap/v4-periphery/src/libraries/Actions.sol';
import {LiquidityAmounts} from '@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol';

import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';

import {AutoLP} from '@flaunch/hooks/AutoLP.sol';
import {UnwindAutoLPAction} from '@flaunch/treasury/actions/UnwindAutoLP.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';

import {IDeployAutoLPAction} from '@flaunch-interfaces/IDeployAutoLPAction.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {IOracle} from '@flaunch-interfaces/IOracle.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Treasury action that owns the AutoLP position NFT for each Flaunch pool. Responsibilities:
 *
 *   - On `execute`, pulls the requested currency amounts from the calling treasury (only the
 *     canonical {MemecoinTreasury} for the supplied pool key may call), mints a new position
 *     the first time a pool is seen (or increases an existing one), and immediately compounds
 *     any pending fees.
 *   - On `compoundFees` (called from the AutoLP hook's `afterSwap` or by anyone externally),
 *     collects accrued fees, forwards the native leg to the cached memecoin treasury and
 *     re-deposits the memecoin leg back into the position.
 *   - On `unwind` (called by the wired-in {UnwindAutoLPAction}), tears down the position and
 *     forwards the freed currencies, respecting caller-supplied slippage minimums.
 *   - The owner can recover the underlying ERC721 in an emergency, but only ever to the
 *     canonical {MemecoinTreasury} for that pool.
 *
 * State is keyed by the AutoLP poolId because that's where the position physically lives. The
 * memecoin currency is derived from "whichever side of the {PoolKey} isn't the protocol's
 * native token", so no extra mapping is required.
 */
contract DeployAutoLPAction is ITreasuryAction, IDeployAutoLPAction, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using MemecoinFinder for PoolKey;

    error InvalidTokenId();
    error InvalidPoolKey();
    error UnwindActionAlreadySet();
    error Unauthorized();
    /// @notice The Flaunch pool's price Oracle has no recorded observations, so its `twapTick`
    ///         would degrade to a manipulable spot price. See {_initializeIfNeeded}.
    error FlaunchPoolOracleNotSeeded();

    /**
     * Storage for AutoLP position metadata, keyed by AutoLP poolId.
     *
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param liquidity The current liquidity of the position
     * @param treasury The canonical {MemecoinTreasury} address cached at first mint; native-leg
     *                 fees are always forwarded here, even if the memecoin proxy later returns
     *                 a different value
     */
    struct PoolPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address treasury;
    }

    /// @notice Protocol native token used in flaunch pools (e.g. flETH)
    Currency public immutable nativeToken;

    /// @notice The AutoLP hook that gates pool init and triggers `compoundFees`
    AutoLP public immutable autoLPHook;

    /// @notice Uniswap v4 periphery PositionManager that holds our position NFTs
    IPositionManager public immutable v4PositionManager;

    /// @notice Permit2 allowance transfer contract (used by v4 periphery to pull funds)
    IAllowanceTransfer public immutable permit2;

    /// @notice Shared price Oracle used to seed the AutoLP pool from a manipulation-resistant
    ///         TWAP rather than the Flaunch pool's spot price. See {_initializeIfNeeded}.
    IOracle public immutable oracle;

    /// @notice Wired-in unwind action; only this contract may call {unwind}
    UnwindAutoLPAction public unwindAutoLPAction;

    /// @notice Maps AutoLP poolId to the ERC721 tokenId held by this contract for that pool
    mapping(PoolId autoLPPoolId => uint tokenId) public poolPositionTokenId;

    /// @notice Per-AutoLP-pool position metadata
    mapping(PoolId autoLPPoolId => PoolPosition position) public positions;

    /**
     * @notice Default half-width (in ticks) used when creating a new centered range.
     *
     * @dev Updating this value only affects positions minted **after** the change; existing
     *      positions retain whatever range was committed on their first deposit.
     */
    int24 public defaultTickHalfWidth = 600;

    /**
     * @param _nativeToken Protocol native token used in flaunch pools (e.g. flETH)
     * @param _autoLPHook AutoLP hook that will route `compoundFees` calls to us
     * @param _v4PositionManager Uniswap v4 PositionManager that mints/holds our position NFTs
     * @param _permit2 Permit2 instance used by the v4 periphery to pull tokens for settlements
     * @param _oracle Shared price {Oracle} consulted by {_initializeIfNeeded} for a manipulation-
     *                resistant TWAP seed price when the AutoLP pool is first created
     */
    constructor(
        address _nativeToken,
        AutoLP _autoLPHook,
        IPositionManager _v4PositionManager,
        IAllowanceTransfer _permit2,
        IOracle _oracle
    ) Ownable(msg.sender) {
        nativeToken = Currency.wrap(_nativeToken);
        autoLPHook = _autoLPHook;
        v4PositionManager = _v4PositionManager;
        permit2 = _permit2;
        oracle = _oracle;
    }

    /**
     * One-shot setter for the unwind action. Called once after deployment to break the circular
     * dependency between `DeployAutoLPAction` and `UnwindAutoLPAction`.
     *
     * @param _unwindAutoLPAction The {UnwindAutoLPAction} that may call {unwind}
     */
    function setUnwindAction(
        UnwindAutoLPAction _unwindAutoLPAction
    ) external onlyOwner {
        if (address(unwindAutoLPAction) != address(0)) {
            revert UnwindActionAlreadySet();
        }
        unwindAutoLPAction = _unwindAutoLPAction;
    }

    /**
     * @notice Updates the default half-width applied to fresh positions. Existing positions
     *         retain their stored tick range; only positions created after this call see the
     *         new default.
     *
     * @param _halfWidth The new default half-width
     */
    function setDefaultTickHalfWidth(
        int24 _halfWidth
    ) external onlyOwner {
        require(_halfWidth > 0, 'half-width must be positive');
        defaultTickHalfWidth = _halfWidth;
    }

    /**
     * Deploys treasury balances into the AutoLP position and runs an opportunistic compound.
     * Restricted to the canonical {MemecoinTreasury} for the supplied pool key — this both
     * prevents tick-range squatting attacks and ensures the cached treasury address always
     * points at the legitimate beneficiary.
     *
     * @dev `_data` = abi.encode(uint amount0, uint amount1) where amount0/1 are denominated in
     *      the Flaunch pool's currency0/1 ordering (which is identical to the AutoLP key's
     *      ordering).
     *
     * @param _flaunchPoolKey The Flaunch {PoolKey} describing the (currency0, currency1) pair
     * @param _data Encoded `(uint amount0, uint amount1)` to deposit into the AutoLP position
     */
    function execute(
        PoolKey memory _flaunchPoolKey,
        bytes memory _data
    ) external override nonReentrant {
        // Only the canonical memecoin treasury for this pool may invoke `execute`. This locks
        // out anonymous depositors from front-running the first call and squatting on the
        // position's tick range.
        IMemecoin memecoin = _flaunchPoolKey.memecoin(Currency.unwrap(nativeToken));
        address treasury = memecoin.treasury();
        if (msg.sender != treasury) {
            revert Unauthorized();
        }

        (uint amount0, uint amount1) = abi.decode(_data, (uint, uint));

        // Compute the AutoLP key once from the Flaunch key
        PoolKey memory autoLPPoolKey = autoLPHook.getLPPoolKey(_flaunchPoolKey);

        // Lazily seed the AutoLP pool with the Flaunch pool's price the first time we see it
        _initializeIfNeeded(_flaunchPoolKey, autoLPPoolKey);

        // Make sure the periphery PositionManager can pull tokens via Permit2
        _ensurePermit2Approvals(autoLPPoolKey);

        // Snapshot per-currency balances BEFORE pulling tokens. We use this snapshot to compute
        // the delta this call introduces to our balance and refund any unused portion back to
        // the treasury after `_increasePosition`. Working in delta-space (rather than reading
        // absolute balances) is critical because this contract holds funds for many pools
        // simultaneously — e.g. accumulated `nativeToken` from other pools' compounds. A naked
        // `balanceOf(this)` sweep would steal from those.
        uint deposit0Before = autoLPPoolKey.currency0.balanceOf(address(this));
        uint deposit1Before = autoLPPoolKey.currency1.balanceOf(address(this));

        // Pull the requested amounts from the calling treasury into this contract
        if (amount0 != 0) {
            IERC20(Currency.unwrap(autoLPPoolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 != 0) {
            IERC20(Currency.unwrap(autoLPPoolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        }

        // Cache the legitimate treasury for this pool exactly once. After this point, every
        // future `compoundFees` call uses the cached value rather than re-asking the memecoin
        // proxy, which protects against post-init upgrades that change the return value.
        PoolPosition storage p = positions[autoLPPoolKey.toId()];
        if (p.treasury == address(0)) {
            p.treasury = treasury;
        }

        // Mint a new position or increase the existing one
        _increasePosition(autoLPPoolKey, amount0, amount1);

        // Refund any portion of the just-pulled deposit that the periphery did NOT consume
        // (price moved through our range, single-sided amount on the wrong side, rounding,
        // etc.). The delta vs `deposit{0,1}Before` is exactly `amount_pulled - amount_consumed`
        // — never anything that belonged to a different pool.
        uint deposit0After = autoLPPoolKey.currency0.balanceOf(address(this));
        uint deposit1After = autoLPPoolKey.currency1.balanceOf(address(this));
        if (deposit0After > deposit0Before) {
            autoLPPoolKey.currency0.transfer(msg.sender, deposit0After - deposit0Before);
        }
        if (deposit1After > deposit1Before) {
            autoLPPoolKey.currency1.transfer(msg.sender, deposit1After - deposit1Before);
        }

        // Realize any fees that may have accrued since the last touch. `_compoundFees` performs
        // its own per-call delta sweep so any memecoin dust it produces is forwarded to the
        // cached treasury, not stranded on the contract.
        _compoundFees(autoLPPoolKey);

        emit ActionExecuted(_flaunchPoolKey, -int(amount0), -int(amount1));
    }

    /**
     * Collects accrued LP fees for the position bound to `_autoLPPoolKey`, sends the native-leg
     * fees to the cached memecoin treasury and re-deposits the memecoin-leg fees back into the
     * position.
     *
     * Safe to call whether or not the PoolManager is currently unlocked: when called from inside
     * the hook's `afterSwap`, the periphery's `modifyLiquiditiesWithoutUnlock` path is used so
     * we don't try to acquire the unlock a second time.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey} whose position should be compounded
     */
    function compoundFees(
        PoolKey memory _autoLPPoolKey
    ) public override nonReentrant {
        _compoundFees(_autoLPPoolKey);
    }

    /**
     * Internal compound entrypoint. Split out so the public `compoundFees` can stay
     * `nonReentrant` while `execute` (also `nonReentrant`) can still call it without colliding
     * with the guard.
     */
    function _compoundFees(
        PoolKey memory _autoLPPoolKey
    ) internal {
        PoolId poolId = _autoLPPoolKey.toId();
        uint tokenId = poolPositionTokenId[poolId];

        // No-op if we don't yet hold a position for this pool
        if (tokenId == 0) {
            return;
        }

        // Defense in depth: refuse keys where neither side is the protocol native token. This
        // would otherwise cause the entire balance to be classified as the memecoin leg.
        bool nativeIs0 = Currency.unwrap(_autoLPPoolKey.currency0) == Currency.unwrap(nativeToken);
        bool nativeIs1 = Currency.unwrap(_autoLPPoolKey.currency1) == Currency.unwrap(nativeToken);
        if (!nativeIs0 && !nativeIs1) {
            revert InvalidPoolKey();
        }

        // Snapshot balances so we can isolate exactly what fees were collected
        uint before0 = _autoLPPoolKey.currency0.balanceOf(address(this));
        uint before1 = _autoLPPoolKey.currency1.balanceOf(address(this));

        _collectFees(tokenId, _autoLPPoolKey.currency0, _autoLPPoolKey.currency1);

        uint received0 = _autoLPPoolKey.currency0.balanceOf(address(this)) - before0;
        uint received1 = _autoLPPoolKey.currency1.balanceOf(address(this)) - before1;

        if (received0 == 0 && received1 == 0) {
            return;
        }

        // Split the collected fees into "native" and "memecoin" legs
        uint nativeFees = nativeIs0 ? received0 : received1;
        uint memecoinFees = nativeIs0 ? received1 : received0;

        // Resolve the cached treasury once for this call. It must always be populated for a
        // pool with a live tokenId because `execute` writes it on first deposit.
        address treasuryRecipient = positions[poolId].treasury;
        if (treasuryRecipient == address(0)) {
            revert InvalidTokenId();
        }

        // Forward native fees to the cached memecoin treasury for this pool
        if (nativeFees != 0) {
            nativeToken.transfer(treasuryRecipient, nativeFees);
        }

        // Re-deposit memecoin-side fees back into the position. If the in-range price has moved
        // past the relevant tick (e.g. single-sided amount0 above the upper tick), the call
        // returns 0 liquidity and consumes nothing. Any residual is then swept to the treasury
        // below — never stranded on the contract.
        if (memecoinFees != 0) {
            _increasePosition(_autoLPPoolKey, nativeIs0 ? 0 : memecoinFees, nativeIs0 ? memecoinFees : 0);
        }

        // Sweep any memecoin-side residual produced by THIS call to the cached treasury. The
        // delta is computed against the pre-collect snapshot (`before0` / `before1`), so it
        // strictly captures `(memecoinFees - amount_redeposited)` and never touches any
        // pre-existing balance that belongs to a different pool.
        Currency memecoinCurrency = nativeIs0 ? _autoLPPoolKey.currency1 : _autoLPPoolKey.currency0;
        uint memecoinBefore = nativeIs0 ? before1 : before0;
        uint memecoinAfter = memecoinCurrency.balanceOf(address(this));
        if (memecoinAfter > memecoinBefore) {
            memecoinCurrency.transfer(treasuryRecipient, memecoinAfter - memecoinBefore);
        }
    }

    /**
     * Tears the AutoLP position down to zero liquidity, returning the freed currencies to the
     * supplied recipient. Only callable by the wired-in {UnwindAutoLPAction}. Slippage
     * minimums are forwarded directly into the periphery `DECREASE_LIQUIDITY` action.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey} to unwind
     * @param _recipient The address to receive the freed token0/1
     * @param _amount0Min The minimum amount of currency0 the unwinder is willing to accept
     * @param _amount1Min The minimum amount of currency1 the unwinder is willing to accept
     */
    function unwind(
        PoolKey memory _autoLPPoolKey,
        address _recipient,
        uint128 _amount0Min,
        uint128 _amount1Min
    ) external nonReentrant returns (uint amount0_, uint amount1_) {
        if (msg.sender != address(unwindAutoLPAction)) {
            revert Unauthorized();
        }

        PoolId poolId = _autoLPPoolKey.toId();
        uint tokenId = poolPositionTokenId[poolId];
        if (tokenId == 0) {
            revert InvalidTokenId();
        }

        // Snapshot balances so the (fees + freed liquidity) are forwarded in full
        uint before0 = _autoLPPoolKey.currency0.balanceOf(address(this));
        uint before1 = _autoLPPoolKey.currency1.balanceOf(address(this));

        // DECREASE_LIQUIDITY by the full position liquidity automatically also collects fees
        uint128 liquidity = v4PositionManager.getPositionLiquidity(tokenId);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint(liquidity), _amount0Min, _amount1Min, bytes(''));
        params[1] = abi.encode(_autoLPPoolKey.currency0, _autoLPPoolKey.currency1, address(this));
        _executePosm(actions, params);

        amount0_ = _autoLPPoolKey.currency0.balanceOf(address(this)) - before0;
        amount1_ = _autoLPPoolKey.currency1.balanceOf(address(this)) - before1;

        // Forward to the requested recipient
        if (amount0_ != 0) {
            _autoLPPoolKey.currency0.transfer(_recipient, amount0_);
        }
        if (amount1_ != 0) {
            _autoLPPoolKey.currency1.transfer(_recipient, amount1_);
        }

        // Clear local state. The ERC721 itself is left empty on the periphery PositionManager;
        // a fresh deposit for the same pool will mint a brand-new tokenId.
        delete poolPositionTokenId[poolId];
        delete positions[poolId];
    }

    /**
     * Owner-only ERC721 recovery escape hatch. The NFT is always sent to `owner()` — there is
     * no caller-supplied recipient — so the owner key cannot redirect funds to an arbitrary
     * third party. The recipient is the contract owner (rather than the per-pool memecoin
     * treasury) because the {MemecoinTreasury} is not built to operate a Uniswap v4 LP NFT;
     * recovery is reserved for the operational multisig that wired the system up.
     *
     * @param _autoLPPoolId The AutoLP {PoolId} whose position NFT should be recovered to the
     *                      contract owner
     */
    function recoverPositionNFT(
        PoolId _autoLPPoolId
    ) external onlyOwner nonReentrant {
        uint tokenId = poolPositionTokenId[_autoLPPoolId];
        if (tokenId == 0) {
            revert InvalidTokenId();
        }

        IERC721(address(v4PositionManager)).transferFrom(address(this), owner(), tokenId);

        delete poolPositionTokenId[_autoLPPoolId];
        delete positions[_autoLPPoolId];
    }

    /**
     * Lazily initializes the AutoLP pool, seeding its starting price from the Flaunch pool's
     * manipulation-resistant TWAP rather than its raw spot.
     *
     * @dev [F-8] The previous implementation read `slot0` on the Flaunch pool, which is
     *      manipulable by an atomic swap inside the same transaction (e.g. a creator skewing
     *      the Flaunch spot just before the first AutoLP deposit to bias the AutoLP opening
     *      price). Reading from the shared {Oracle} TWAP closes that vector — the spot tick
     *      is passed only as the warm-up fallback for pools whose first observation is
     *      recorded in the same block.
     *
     * @param _flaunchPoolKey The Flaunch {PoolKey} to read the seeding price from
     * @param _autoLPPoolKey The AutoLP {PoolKey} to initialize
     */
    function _initializeIfNeeded(
        PoolKey memory _flaunchPoolKey,
        PoolKey memory _autoLPPoolKey
    ) internal {
        IPoolManager pm = v4PositionManager.poolManager();

        // sqrtPriceX96 == 0 indicates an uninitialized pool
        (uint160 autoLPSqrtPriceX96,,,) = pm.getSlot0(_autoLPPoolKey.toId());
        if (autoLPSqrtPriceX96 != 0) {
            return;
        }

        // Seed from the Flaunch pool's TWAP. `oracle.twapTick` takes the current tick as the
        // warm-up fallback so pools that have just been initialised still receive a sensible
        // price - the PositionManager records an observation at flaunch time so this fallback
        // is effectively unreachable in production flows.
        PoolId flaunchPoolId = _flaunchPoolKey.toId();

        // [F-12] Defense-in-depth: refuse to seed the AutoLP pool when the Flaunch pool's Oracle
        // has no history. With `cardinality == 0`, `twapTick` silently degrades to the passed-in
        // spot tick, which an atomic same-transaction swap can skew - opening the AutoLP pool at a
        // manipulated price. The F-1 cluster records a genesis observation for every (including
        // Any) pool at flaunch time, so a seeded Flaunch pool is the expected state here; fail
        // closed rather than seeding off-market.
        if (oracle.observationState(flaunchPoolId).cardinality == 0) {
            revert FlaunchPoolOracleNotSeeded();
        }

        (, int24 flaunchCurrentTick,,) = pm.getSlot0(flaunchPoolId);
        int24 seedTick = oracle.twapTick(flaunchPoolId, flaunchCurrentTick);
        uint160 seedSqrtPriceX96 = TickMath.getSqrtPriceAtTick(seedTick);

        autoLPHook.initializePool(_flaunchPoolKey, seedSqrtPriceX96);
    }

    /**
     * Ensures both Permit2 approvals are set so the v4 periphery PositionManager can pull
     * tokens from us during settlement. Idempotent.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey} whose currencies should be approved
     */
    function _ensurePermit2Approvals(
        PoolKey memory _autoLPPoolKey
    ) internal {
        _approveCurrencyOnPermit2(_autoLPPoolKey.currency0);
        _approveCurrencyOnPermit2(_autoLPPoolKey.currency1);
    }

    /**
     * Sets `IERC20.approve(permit2, max)` (via `forceApprove`, so USDT-style allowance resets
     * are handled) and `permit2.approve(currency, posm, max, max)` if not already in place.
     * No-op for native ETH (Flaunch's `nativeToken` is the flETH ERC20 wrapper, so this branch
     * is dead code in practice but kept for portability).
     *
     * @param _currency The currency to approve
     */
    function _approveCurrencyOnPermit2(
        Currency _currency
    ) internal {
        address token = Currency.unwrap(_currency);
        if (token == address(0)) {
            return;
        }

        if (IERC20(token).allowance(address(this), address(permit2)) == 0) {
            IERC20(token).forceApprove(address(permit2), type(uint).max);
        }

        (uint160 amount, uint48 expiration,) = permit2.allowance(address(this), token, address(v4PositionManager));
        if (amount == 0 || expiration <= block.timestamp) {
            permit2.approve(token, address(v4PositionManager), type(uint160).max, type(uint48).max);
        }
    }

    /**
     * Mints (first call) or increases (subsequent calls) the AutoLP position with the supplied
     * single-sided or two-sided amounts.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey}
     * @param _amount0 The amount of currency0 to deposit
     * @param _amount1 The amount of currency1 to deposit
     */
    function _increasePosition(
        PoolKey memory _autoLPPoolKey,
        uint _amount0,
        uint _amount1
    ) internal {
        if (_amount0 == 0 && _amount1 == 0) {
            return;
        }

        PoolId poolId = _autoLPPoolKey.toId();
        uint liquidity = _resolveLiquidityAndRange(poolId, _autoLPPoolKey.tickSpacing, _amount0, _amount1);
        if (liquidity == 0) {
            return;
        }

        uint tokenId = _mintOrIncrease(poolId, _autoLPPoolKey, liquidity, _amount0, _amount1);
        positions[poolId].liquidity = v4PositionManager.getPositionLiquidity(tokenId);
    }

    /**
     * Resolves the liquidity supported by the supplied amounts, picking a tick range on first
     * use and persisting it **only if** the chosen range yields non-zero liquidity. This
     * prevents a tiny single-sided seed from permanently committing a biased range.
     */
    function _resolveLiquidityAndRange(
        PoolId _poolId,
        int24 _tickSpacing,
        uint _amount0,
        uint _amount1
    ) internal returns (uint liquidity_) {
        PoolPosition storage p = positions[_poolId];
        (uint160 sqrtPriceX96, int24 currentTick,,) = v4PositionManager.poolManager().getSlot0(_poolId);

        if (p.tickLower == 0 && p.tickUpper == 0) {
            (int24 candidateLower, int24 candidateUpper) = _recommendTickRange(currentTick, _tickSpacing, _amount0, _amount1);

            uint128 candidate = _liquidityFromAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(candidateLower), TickMath.getSqrtPriceAtTick(candidateUpper), _amount0, _amount1
            );

            if (candidate == 0) {
                return 0;
            }

            (p.tickLower, p.tickUpper) = (candidateLower, candidateUpper);
            return candidate;
        }

        liquidity_ = _liquidityFromAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(p.tickLower), TickMath.getSqrtPriceAtTick(p.tickUpper), _amount0, _amount1
        );
    }

    /**
     * Encodes and dispatches a MINT (first time) or INCREASE (subsequent) action through the
     * v4 periphery, returning the tokenId in use after the call.
     */
    function _mintOrIncrease(
        PoolId _poolId,
        PoolKey memory _autoLPPoolKey,
        uint _liquidity,
        uint _amount0,
        uint _amount1
    ) internal returns (uint tokenId_) {
        tokenId_ = poolPositionTokenId[_poolId];
        bool minting = (tokenId_ == 0);

        bytes memory actions =
            abi.encodePacked(uint8(minting ? Actions.MINT_POSITION : Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        if (minting) {
            // Reserve the next tokenId; periphery will assign exactly this id when minting
            tokenId_ = v4PositionManager.nextTokenId();
            poolPositionTokenId[_poolId] = tokenId_;
            params[0] = _encodeMintParams(_autoLPPoolKey, _poolId, _liquidity, _amount0, _amount1);
        } else {
            params[0] = abi.encode(tokenId_, _liquidity, uint128(_amount0), uint128(_amount1), bytes(''));
        }
        params[1] = abi.encode(_autoLPPoolKey.currency0, _autoLPPoolKey.currency1);

        _executePosm(actions, params);
    }

    /**
     * Encodes MINT_POSITION params; pulled out into its own frame to keep `_mintOrIncrease`
     * within the EVM's stack budget.
     */
    function _encodeMintParams(
        PoolKey memory _autoLPPoolKey,
        PoolId _poolId,
        uint _liquidity,
        uint _amount0,
        uint _amount1
    ) internal view returns (bytes memory) {
        PoolPosition storage p = positions[_poolId];
        return
            abi.encode(_autoLPPoolKey, p.tickLower, p.tickUpper, _liquidity, uint128(_amount0), uint128(_amount1), address(this), bytes(''));
    }

    /**
     * Computes liquidity from supplied amounts, including correct single-sided semantics when
     * one of the amounts is zero (which `LiquidityAmounts.getLiquidityForAmounts` would otherwise
     * truncate to zero in-range).
     */
    function _liquidityFromAmounts(
        uint160 _sqrt,
        uint160 _sqrtLower,
        uint160 _sqrtUpper,
        uint _amount0,
        uint _amount1
    ) internal pure returns (uint128 liquidity_) {
        if (_amount0 != 0 && _amount1 != 0) {
            liquidity_ = LiquidityAmounts.getLiquidityForAmounts(_sqrt, _sqrtLower, _sqrtUpper, _amount0, _amount1);
        } else if (_amount0 != 0) {
            // [F-11] Single-sided currency0 is only fully consumed when the price sits at or
            // below the range's lower bound (the range is then entirely currency0). If the price
            // is above the range, currency0 is not consumed; if the range STRADDLES the price
            // (`_sqrtLower < _sqrt < _sqrtUpper`) the position also requires a non-zero currency1
            // amount, which a single-sided deposit does not supply and the periphery's
            // `SlippageCheck.validateMaxIn` would reject (reverting the whole compound). Return 0
            // in both cases so `_increasePosition` no-ops and `_compoundFees` sweeps the residual
            // to the treasury instead of reverting.
            if (_sqrt > _sqrtLower) {
                return 0;
            }
            liquidity_ = LiquidityAmounts.getLiquidityForAmount0(_sqrtLower, _sqrtUpper, _amount0);
        } else {
            // [F-11] Single-sided currency1 is only fully consumed when the price sits at or above
            // the range's upper bound (the range is then entirely currency1). If the price is
            // below the range, currency1 is not consumed; if the range STRADDLES the price
            // (`_sqrtLower < _sqrt < _sqrtUpper`) the position also requires a non-zero currency0
            // amount, which a single-sided deposit does not supply and the periphery's
            // `SlippageCheck.validateMaxIn` would reject (reverting the whole compound). Return 0
            // in both cases so `_increasePosition` no-ops and `_compoundFees` sweeps the residual
            // to the treasury instead of reverting.
            if (_sqrt < _sqrtUpper) {
                return 0;
            }
            liquidity_ = LiquidityAmounts.getLiquidityForAmount1(_sqrtLower, _sqrtUpper, _amount1);
        }
    }

    /**
     * Collects pending fees for `_tokenId` without changing position liquidity.
     */
    function _collectFees(
        uint _tokenId,
        Currency _c0,
        Currency _c1
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_tokenId, uint(0), uint128(0), uint128(0), bytes(''));
        params[1] = abi.encode(_c0, _c1, address(this));
        _executePosm(actions, params);
    }

    /**
     * Routes a periphery call through `modifyLiquidities` (acquires unlock) or
     * `modifyLiquiditiesWithoutUnlock` (already inside an unlock) depending on the PoolManager's
     * current lock state. This auto-detection is intentional: it lets the same compound flow
     * run from external txs (where we must acquire the lock) and from `afterSwap` callbacks
     * (where the swap caller already holds it). The PositionManager's nested calls settle their
     * own deltas, so they don't bleed into the swap caller's accounting.
     */
    function _executePosm(
        bytes memory _actions,
        bytes[] memory _params
    ) internal {
        IPoolManager pm = v4PositionManager.poolManager();
        if (pm.isUnlocked()) {
            v4PositionManager.modifyLiquiditiesWithoutUnlock(_actions, _params);
        } else {
            v4PositionManager.modifyLiquidities(abi.encode(_actions, _params), block.timestamp + 1);
        }
    }

    /**
     * Picks a tick range centered on `_currentTick` using the configured half-width, clamping
     * the center into `[minUsableTick, maxUsableTick]` first and then performing all width
     * arithmetic in `int256` so we never overflow `int24` mid-calculation. For single-sided
     * seeds the range is shifted to the appropriate side of the current price so the deposit
     * fits.
     *
     * @param _currentTick The current tick of the AutoLP pool
     * @param _tickSpacing The pool's tick spacing
     * @param _amount0 The amount of currency0 being seeded
     * @param _amount1 The amount of currency1 being seeded
     */
    function _recommendTickRange(
        int24 _currentTick,
        int24 _tickSpacing,
        uint _amount0,
        uint _amount1
    ) internal view returns (int24 tickLower_, int24 tickUpper_) {
        int24 minTick = TickMath.minUsableTick(_tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(_tickSpacing);

        // Clamp the center BEFORE adding/subtracting widths so we cannot revert in checked math
        // when `_currentTick` is near `±887272`.
        int24 centerTick = _alignToSpacing(_currentTick, _tickSpacing);
        if (centerTick < minTick) {
            centerTick = minTick;
        }
        if (centerTick > maxTick) {
            centerTick = maxTick;
        }

        int halfWidth = int(_normalizeWidth(defaultTickHalfWidth, _tickSpacing));
        int fullWidth = halfWidth * 2;
        int spacing = int(_tickSpacing);
        int center = int(centerTick);

        int lower;
        int upper;

        if (_amount0 == 0 && _amount1 == 0) {
            lower = center - halfWidth;
            upper = center + halfWidth;
        } else if (_amount0 == 0) {
            // Pure currency1 deposit: range must sit fully below the current price
            upper = center - spacing;
            lower = upper - fullWidth;
        } else if (_amount1 == 0) {
            // Pure currency0 deposit: range must sit fully above the current price
            lower = center + spacing;
            upper = lower + fullWidth;
        } else {
            lower = center - halfWidth;
            upper = center + halfWidth;
        }

        // Final clamp + downcast in int256-space, so checked arithmetic never trips
        if (lower < int(minTick)) {
            lower = int(minTick);
        }
        if (upper > int(maxTick)) {
            upper = int(maxTick);
        }
        if (upper <= lower) {
            lower = int(minTick);
            upper = int(maxTick);
        }

        tickLower_ = int24(lower);
        tickUpper_ = int24(upper);
    }

    /**
     * Aligns a tick to a multiple of `_tickSpacing`, rounding toward negative infinity for
     * negative ticks (Uniswap convention).
     */
    function _alignToSpacing(
        int24 _tick,
        int24 _tickSpacing
    ) internal pure returns (int24 aligned_) {
        aligned_ = _tick / _tickSpacing * _tickSpacing;
        if (_tick < 0 && _tick % _tickSpacing != 0) {
            aligned_ -= _tickSpacing;
        }
    }

    /**
     * Rounds `_width` up to the nearest multiple of `_tickSpacing` (and ensures at least one
     * spacing of width). Performs the rounding addition in `int256` so an attacker-controlled
     * `defaultTickHalfWidth` cannot revert via checked arithmetic.
     */
    function _normalizeWidth(
        int24 _width,
        int24 _tickSpacing
    ) internal pure returns (int24 width_) {
        int w = int(_width);
        int spacing = int(_tickSpacing);
        if (w < spacing) {
            w = spacing;
        }
        int remainder = w % spacing;
        if (remainder != 0) {
            w += spacing - remainder;
        }
        // Cap at int24.max so the int24 downcast never wraps. Callers always combine the result
        // with a clamped center, so over-cap is safe (the final tick clamp catches it).
        int maxInt24 = int(int24(type(int24).max));
        if (w > maxInt24) {
            w = maxInt24;
        }
        width_ = int24(w);
    }
}
