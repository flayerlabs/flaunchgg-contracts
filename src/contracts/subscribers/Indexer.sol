// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {EnumerableSetLib} from '@solady/utils/EnumerableSetLib.sol';

import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';

import {IIndexerSubscriber} from '@flaunch-interfaces/IIndexerSubscriber.sol';

/**
 * Creates an evolving list of pools on Flaunch and maps its corresponding token
 * information for onchain lookups.
 */
contract IndexerSubscriber is IIndexerSubscriber, Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using PoolIdLibrary for PoolKey;

    /// Set of verified Flaunch contracts
    EnumerableSetLib.AddressSet internal _verifiedFlaunches;

    /// Maps a PoolId to the token index information
    mapping(PoolId _poolId => Index _index) internal _poolIndex;

    /// Maps a PoolId to a Flaunch contract
    mapping(PoolId _poolId => Flaunch _flaunch) internal _poolFlaunch;

    /// Maps each notifier to the flaunch contract that it will represent
    mapping(address _notifier => address _flaunch) internal _notifierFlaunch;

    /**
     * Registers the owner of the contract.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * Called when the contract is subscribed to the Notifier.
     *
     * We have no subscription requirements, so we can just confirm immediately.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(
        bytes memory /* _data */
    ) public pure returns (bool) {
        return true;
    }

    /**
     * Whenever a token is flaunched, we will index the token information onchain.
     *
     * @dev Called when `afterInitialize` is triggered.
     *
     * @param _poolId The poolId that has been initialized
     * @param _key The notification key
     * @param _data Contains the tokenId, as well as unused params
     */
    function notify(
        PoolId _poolId,
        bytes4 _key,
        bytes calldata _data
    ) public {
        // We only want to deal with the `afterInitialize` key
        if (_key != IHooks.afterInitialize.selector) {
            return;
        }

        // If the notifier has not been allocated a flaunch contract, then we cannot
        // proceed with our indexing.
        if (_notifierFlaunch[msg.sender] == address(0)) {
            return;
        }

        // Register our flaunch contract relative to the notifier
        Flaunch flaunch = Flaunch(_notifierFlaunch[msg.sender]);

        // Unpack our tokenId from our passed initialization data
        (uint tokenId) = abi.decode(_data, (uint));

        // Store our token information, relative to the PoolId
        _poolIndex[_poolId] = Index({
            flaunch: address(flaunch),
            memecoin: flaunch.memecoin(tokenId),
            memecoinTreasury: flaunch.memecoinTreasury(tokenId),
            tokenId: tokenId
        });

        // Store our flaunch contract relative to the PoolId
        _poolFlaunch[_poolId] = flaunch;
    }

    /**
     * Returns the index information for a given PoolId.
     *
     * @dev To conform to existing integrations, we return the struct members individually.
     *
     * @param _poolId The PoolId to get the index information for
     *
     * @return flaunch_ The {Flaunch} contract that launched the token
     * @return memecoin_ The memecoin address
     * @return memecoinTreasury_ The memecoin treasury address
     * @return tokenId_ The tokenId created with the pool (0 if burned)
     */
    function poolIndex(
        PoolId _poolId
    ) public view returns (address flaunch_, address memecoin_, address memecoinTreasury_, uint tokenId_) {
        // Get the index information for the given PoolId
        Index memory poolIndex_ = _poolIndex[_poolId];

        // Before returning the tokenId that was used to create the pool, we need to first check if
        // the ownership of the token has been burned. If it has been burned and future contract calls
        // depend on this value, then they could receive a revert.
        if (poolIndex_.tokenId != 0) {
            try _poolFlaunch[_poolId].ownerOf(poolIndex_.tokenId) returns (
                address owner
            ) {
            // ..
            }
            catch {
                poolIndex_.tokenId = 0;
            }
        }

        return (poolIndex_.flaunch, poolIndex_.memecoin, poolIndex_.memecoinTreasury, poolIndex_.tokenId);
    }

    /**
     * For tokens that were flaunched before this Notifier was put in place, we allow the
     * information to be back-filled. The data is validated before being written and will
     * revert if it is deemed invalid.
     *
     * @param _params Information to add legacy indexes
     */
    function addIndex(
        AddIndexParams[] calldata _params
    ) public {
        // Declare our global variables
        AddIndexParams memory params;
        Flaunch flaunch;
        PoolId poolId;
        uint tokenId;

        // Iterate over all tokens to sync them
        uint paramsLength = _params.length;
        for (uint i; i < paramsLength; ++i) {
            params = _params[i];
            flaunch = Flaunch(params.flaunch);

            // Verify that the Flaunch contract is verified
            if (!_verifiedFlaunches.contains(params.flaunch)) {
                revert FlaunchNotVerified(params.flaunch);
            }

            // Iterate over our tokenIds
            uint tokenIdsLength = params.tokenIds.length;
            for (uint k; k < tokenIdsLength; ++k) {
                tokenId = params.tokenIds[k];

                /**
                 * Validate the data provided by checking the token information and confirming
                 * that it matches the tokenId provided. We can do this because our protocol has
                 * a uni-directional lookup which is why this subscriber is created to make it
                 * multi-directional.
                 */

                // Confirm that the memecoin correctly matches the tokenId
                address memecoin = flaunch.memecoin(tokenId);
                if (flaunch.tokenId(memecoin) != tokenId) {
                    revert InvalidTokenId(address(flaunch), tokenId);
                }

                // Find the PoolKey by the memecoin address
                poolId = flaunch.positionManager().poolKey(memecoin).toId();

                // Store our validated index data
                _poolIndex[poolId] = Index({
                    flaunch: address(flaunch), memecoin: memecoin, memecoinTreasury: flaunch.memecoinTreasury(tokenId), tokenId: tokenId
                });

                // Store our flaunch contract relative to the PoolId
                _poolFlaunch[poolId] = flaunch;

                emit PoolIndexed(poolId, address(flaunch), memecoin, flaunch.memecoinTreasury(tokenId), tokenId);
            }
        }
    }

    /**
     * Allows our owner to set {Flaunch} contracts for each {Notifier}.
     *
     * @param _notifier The {Notifier} contract address
     * @param _flaunch The {Flaunch} contract of the Notifier
     */
    function setNotifierFlaunch(
        address _notifier,
        address _flaunch
    ) public onlyOwner {
        _notifierFlaunch[_notifier] = _flaunch;
    }

    /**
     * Allows the owner to update the list of verified Flaunch contracts that can be assigned
     * during the `addIndex` function.
     *
     * @param _flaunch The {Flaunch} contract to add to the list
     */
    function addVerifiedFlaunch(
        address _flaunch
    ) public onlyOwner {
        _verifiedFlaunches.add(_flaunch);
        emit FlaunchVerified(_flaunch, true);
    }

    /**
     * Allows the owner to remove a {Flaunch} contract from the list of verified Flaunch contracts.
     *
     * @param _flaunch The {Flaunch} contract to remove from the list
     */
    function removeVerifiedFlaunch(
        address _flaunch
    ) public onlyOwner {
        _verifiedFlaunches.remove(_flaunch);
        emit FlaunchVerified(_flaunch, false);
    }

    /**
     * Checks if a {Flaunch} contract is verified and can be used in addIndex.
     *
     * @param _flaunch The {Flaunch} contract address to check
     * @return verified_ True if the Flaunch contract is verified, false otherwise
     */
    function isVerifiedFlaunch(
        address _flaunch
    ) public view returns (bool verified_) {
        return _verifiedFlaunches.contains(_flaunch);
    }
}
