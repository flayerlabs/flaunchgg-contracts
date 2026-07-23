// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {BidWall} from '@flaunch/bidwall/BidWall.sol';

/**
 * A BidWall that uses the `AnyPositionManager` contract to get the treasury address for a given memecoin.
 */
contract AnyBidWall is BidWall {
    constructor(
        address _nativeToken,
        address _poolManager,
        address _protocolOwner
    ) BidWall(_nativeToken, _poolManager, _protocolOwner) {
        // ..
    }

    /**
     * Overrides the `_getMemecoinTreasury` function to use the `AnyPositionManager` contract.
     *
     * @param _poolKey The {PoolKey} that we are finding the treasury for
     * @param _memecoin The address of the memecoin
     *
     * @return memecoinTreasury_ The treasury address for the memecoin
     */
    function _getMemecoinTreasury(
        PoolKey memory _poolKey,
        address _memecoin
    ) internal view override returns (address memecoinTreasury_) {
        memecoinTreasury_ = AnyPositionManager(payable(address(_poolKey.hooks))).flaunchContract().memecoinTreasury(_memecoin);
    }

    /**
     * Overrides the `_getMemecoinCreator` function to use the `AnyPositionManager` contract.
     *
     * @param _poolKey The {PoolKey} that we are finding the creator for
     * @param _memecoin The address of the memecoin
     *
     * @return creator_ The creator address for the memecoin
     */
    function _getMemecoinCreator(
        PoolKey memory _poolKey,
        address _memecoin
    ) internal view override returns (address creator_) {
        creator_ = AnyPositionManager(payable(address(_poolKey.hooks))).flaunchContract().creator(_memecoin);
    }
}
