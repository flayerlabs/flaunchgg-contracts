// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

/**
 * A helper library that finds the memecoin contract and it's associated treasury and
 * creator for a given {PoolKey}.
 */
library MemecoinFinder {
    /**
     * Finds the {IMemecoin} attached to a `PoolKey` by assuming it is not the `_nativeToken`.
     *
     * @param _key The `PoolKey` that is being discovered
     * @param _nativeToken The native token used by Flaunch
     *
     * @return The {IMemecoin} contract from the `PoolKey`
     */
    function memecoin(
        PoolKey memory _key,
        address _nativeToken
    ) internal pure returns (IMemecoin) {
        return IMemecoin(Currency.unwrap(Currency.wrap(_nativeToken) == _key.currency0 ? _key.currency1 : _key.currency0));
    }
}
