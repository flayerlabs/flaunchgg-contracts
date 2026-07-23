// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {DeployAutoLPAction} from '@flaunch/treasury/actions/DeployAutoLP.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Wrapper action that routes treasury-initiated unwinds through {DeployAutoLPAction}, which
 * is the actual owner of the AutoLP position NFT. Funds freed by the unwind are forwarded
 * directly to the treasury (the action's caller) by the deploy action.
 */
contract UnwindAutoLPAction is ITreasuryAction {
    using MemecoinFinder for PoolKey;

    error Unauthorized();

    /// @notice The deploy action that owns the AutoLP position NFTs
    DeployAutoLPAction public immutable deployAction;

    /**
     * @param _deployAction The deploy action that owns the AutoLP position
     */
    constructor(
        DeployAutoLPAction _deployAction
    ) {
        deployAction = _deployAction;
    }

    /**
     * Unwinds the AutoLP position for the supplied Flaunch pool. Optionally accepts caller
     * supplied slippage minimums via `_data`; an empty / zero-length payload preserves the
     * legacy "accept any amount" behavior.
     *
     * @dev `_data` is either:
     *      - empty (`""`), in which case slippage minimums default to (0, 0); or
     *      - `abi.encode(uint128 amount0Min, uint128 amount1Min)`, which is forwarded directly
     *        into the periphery `DECREASE_LIQUIDITY` action.
     *
     * @dev Restricted to the canonical {MemecoinTreasury} for the supplied pool, mirroring the
     *      gate already used by {DeployAutoLPAction.execute}. Without this check, anyone could
     *      call `execute` directly and have the freed currencies forwarded to themselves via
     *      the deploy action's `_recipient` parameter.
     *
     * @param _flaunchPoolKey The Flaunch {PoolKey} (NOT the AutoLP key) whose AutoLP position
     *                        should be unwound
     * @param _data Optional `abi.encode(uint128 amount0Min, uint128 amount1Min)` slippage bound
     */
    function execute(
        PoolKey memory _flaunchPoolKey,
        bytes memory _data
    ) external override {
        // Only the canonical memecoin treasury for this pool may invoke `execute`
        IMemecoin memecoin = _flaunchPoolKey.memecoin(Currency.unwrap(deployAction.nativeToken()));
        if (msg.sender != memecoin.treasury()) {
            revert Unauthorized();
        }

        (uint128 amount0Min, uint128 amount1Min) = _data.length == 0 ? (uint128(0), uint128(0)) : abi.decode(_data, (uint128, uint128));

        // Convert Flaunch -> AutoLP key via the hook
        PoolKey memory autoLPPoolKey = deployAction.autoLPHook().getLPPoolKey(_flaunchPoolKey);

        // Tell the deploy action to unwind and send freed funds straight to the calling treasury
        (uint amount0, uint amount1) = deployAction.unwind(autoLPPoolKey, msg.sender, amount0Min, amount1Min);

        emit ActionExecuted(_flaunchPoolKey, int(amount0), int(amount1));
    }
}
