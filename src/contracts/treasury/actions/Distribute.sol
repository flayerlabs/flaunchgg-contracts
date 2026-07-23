// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCastLib} from '@solady/utils/SafeCastLib.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IDistributeAction} from '@flaunch-interfaces/IDistributeAction.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

/**
 * Allows token0 and token1 to be distributed to token holders.
 */
contract DistributeAction is IDistributeAction {
    using SafeCastLib for uint;

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
     * Implement the execute function to burn non-native tokens. This takes the entire caller
     * balance.
     *
     * @param _poolKey The PoolKey to execute against
     * @param _data Array of `Distribution` structs
     */
    function execute(
        PoolKey memory _poolKey,
        bytes memory _data
    ) external override {
        // Unpack our distributions
        Distribution[] memory distributions = abi.decode(_data, (Distribution[]));

        // Define variables that we will be using during our loops
        Currency token;
        Distribution memory distribution;
        uint token0Amount;
        uint token1Amount;

        // Iterate first over our distributions to sum up the amount of flETH to withdraw in
        // a single transaction.
        uint unwrapAmount;
        bool isNativeToken0 = _poolKey.currency0 == nativeToken;
        uint distributionsLength = distributions.length;
        for (uint i; i < distributionsLength; ++i) {
            // Map our distribution
            distribution = distributions[i];

            // Check if the token we are referencing is the native token, and only then will we
            // add the amount value to the amount to unwrap.
            if (distribution.token0 == isNativeToken0) {
                unwrapAmount += distribution.amount;
            }
        }

        // Check if we need to unwrap flETH to ETH
        if (unwrapAmount != 0) {
            IERC20(Currency.unwrap(nativeToken)).transferFrom(msg.sender, address(this), unwrapAmount);
            IFLETH(Currency.unwrap(nativeToken)).withdraw(unwrapAmount);
        }

        // Iterate over our distributions and action them
        for (uint i; i < distributionsLength; ++i) {
            // Reference our distribution
            distribution = distributions[i];

            // Map our token
            token = distribution.token0 ? _poolKey.currency0 : _poolKey.currency1;

            // If the token is native, then we need to unwrap and transfer ETH
            if (token == nativeToken) {
                (bool _sent,) = distribution.recipient.call{value: distribution.amount}('');
                require(_sent, 'ETH Transfer Failed');
            }
            // Otherwise, we can transfer the ERC20 directly
            else {
                IERC20(Currency.unwrap(token)).transferFrom(msg.sender, distribution.recipient, distribution.amount);
            }

            // Add up our running token amounts
            token0Amount += distribution.token0 ? distribution.amount : 0;
            token1Amount += distribution.token0 ? 0 : distribution.amount;
        }

        emit ActionExecuted(_poolKey, -token0Amount.toInt256(), -token1Amount.toInt256());
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive() external payable {}
}
