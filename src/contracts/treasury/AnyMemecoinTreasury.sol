// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';

/**
 * A {MemecoinTreasury} for pools created by the {AnyPositionManager}, whose non-native currency
 * may be a raw imported ERC20 that does not implement `creator()`. Instead of reading the creator
 * from the token directly, we resolve it through the Any manager's `flaunchContract`, mirroring
 * {AnyBidWall._getMemecoinCreator}.
 */
contract AnyMemecoinTreasury is MemecoinTreasury {
    using MemecoinFinder for PoolKey;

    /**
     * Resolves the creator through the {AnyPositionManager} that owns this pool, rather than
     * calling `creator()` on the (possibly imported) memecoin directly.
     *
     * @return The address authorized to execute actions on this treasury
     */
    function _resolveCreator() internal view override returns (address) {
        return AnyPositionManager(payable(address(poolKey.hooks))).flaunchContract().creator(
            address(poolKey.memecoin(nativeToken))
        );
    }
}
