// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Burns non-native tokens held by the {TokenTreasury}.
 */
contract BurnTokensAction is ITreasuryAction {
    /// The native token used by the Flaunch {PositionManager}
    Currency public immutable nativeToken;

    /**
     * Sets the native token used by the Flaunch {PositionManager}
     *
     * @param _nativeToken The ERC20 native token
     */
    constructor(
        address _nativeToken
    ) {
        nativeToken = Currency.wrap(_nativeToken);
    }

    /**
     * Implement the execute function to burn non-native tokens.
     *
     * @dev No additional bytes data is required
     *
     * @param _poolKey The PoolKey to execute against
     */
    function execute(
        PoolKey memory _poolKey,
        bytes memory
    ) external override {
        Currency token = _poolKey.currency0 == nativeToken ? _poolKey.currency1 : _poolKey.currency0;

        // Determine the amount of tokens that we will be burning
        uint amount = token.balanceOf(msg.sender);

        // Burn the tokens by transferring them to the zero address
        IMemecoin(Currency.unwrap(token)).burnFrom(msg.sender, amount);

        // Emit the burn event
        emit ActionExecuted(
            _poolKey, _poolKey.currency0 == nativeToken ? int(0) : -int(amount), _poolKey.currency0 == nativeToken ? -int(amount) : int(0)
        );
    }
}
