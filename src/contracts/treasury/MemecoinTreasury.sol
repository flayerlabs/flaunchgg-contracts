// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from '@solady/utils/Initializable.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {TreasuryActionManager} from '@flaunch/treasury/ActionManager.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';

import {IMemecoinTreasury} from '@flaunch-interfaces/IMemecoinTreasury.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Allows approved actions to be executed by the `PoolCreator` for their specific pool, using
 * tokens in their {MemecoinTreasury}.
 */
contract MemecoinTreasury is IMemecoinTreasury, Initializable, ReentrancyGuard {
    using MemecoinFinder for PoolKey;
    using PoolIdLibrary for PoolKey;

    /// The native token used by the Flaunch {PositionManager}
    address public nativeToken;

    /// The {TreasuryActionManager} contract that stores approved actions
    TreasuryActionManager public actionManager;

    /// The {PositionManager} that fees will be claimed from
    PositionManager public positionManager;

    /// The `PoolKey` that is attached to this {MemecoinTreasury}
    PoolKey public poolKey;

    /**
     * Sets the Flaunch {PositionManager} and native token, and initializes with the `PoolKey`.
     *
     * @param _actionManager The {TreasuryActionManager} contract address
     * @param _nativeToken The native token address used by Flaunch
     * @param _poolKey The pool that is being actioned against
     */
    function initialize(
        address payable _positionManager,
        address _actionManager,
        address _nativeToken,
        PoolKey memory _poolKey
    ) public initializer {
        actionManager = TreasuryActionManager(_actionManager);
        nativeToken = _nativeToken;
        poolKey = _poolKey;
        positionManager = PositionManager(_positionManager);
    }

    /**
     * Executes an approved {ITreasuryAction}.
     *
     * @dev Only to `PoolCreator` can make this call, otherwise reverted with `Unauthorized`
     *
     * @param _action The {ITreasuryAction} address to execute
     * @param _data Additional data that the {ITreasuryAction} may require
     */
    function executeAction(
        address _action,
        bytes memory _data
    ) public nonReentrant {
        // Ensure the action is approved
        if (!actionManager.approvedActions(_action)) {
            revert ActionNotApproved();
        }

        // Make sure the caller is the owner of the corresponding ERC721
        address poolCreator = _resolveCreator();
        if (poolCreator != msg.sender) {
            revert Unauthorized();
        }

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        // Approve all tokens to be used before execution. We use `safeApproveWithRetry` as one of
        // the currencies may be an imported ERC20 with a non-standard `approve` (missing return
        // value, or requiring a reset-to-zero before re-approving).
        SafeTransferLib.safeApproveWithRetry(token0, _action, type(uint).max);
        SafeTransferLib.safeApproveWithRetry(token1, _action, type(uint).max);

        // Claim fees before executing, keeping as fleth to ensure full treasury balances
        claimFees();

        // Call the execute function on the action contract
        ITreasuryAction(_action).execute(poolKey, _data);
        emit ActionExecuted(_action, poolKey, _data);

        // Unapprove all tokens after execution
        SafeTransferLib.safeApprove(token0, _action, 0);
        SafeTransferLib.safeApprove(token1, _action, 0);
    }

    /**
     * Resolves the creator (owner of the corresponding ERC721) that is authorized to execute
     * actions against this treasury. The native {MemecoinTreasury} resolves this directly from
     * the memecoin's `creator()`; the {AnyMemecoinTreasury} overrides this to resolve through
     * the Any manager, as an imported ERC20 may not implement `creator()`.
     *
     * @return The address authorized to execute actions on this treasury
     */
    function _resolveCreator() internal view virtual returns (address) {
        return poolKey.memecoin(nativeToken).creator();
    }

    /**
     * Claims any pending fees allocated to the {MemecoinTreasury}. We do not unwrap the flETH
     * in our claim call to ensure that we keep two persisted tokens as per the {PoolKey}.
     *
     * @dev This call does not require protection and can be called by anyone
     */
    function claimFees() public {
        positionManager.feeEscrow().withdrawFees(address(this), false);
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive() external payable {}
}
