// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

interface IIndexerSubscriber {
    error FlaunchNotVerified(address _flaunch);
    error InvalidTokenId(address _flaunch, uint _tokenId);

    event FlaunchVerified(address indexed _flaunch, bool _verified);
    event PoolIndexed(PoolId indexed _poolId, address indexed _flaunch, address _memecoin, address _memecoinTreasury, uint _tokenId);

    struct Index {
        address flaunch;
        address memecoin;
        address memecoinTreasury;
        uint tokenId;
    }

    struct AddIndexParams {
        address flaunch;
        uint[] tokenIds;
    }

    function subscribe(
        bytes memory _data
    ) external returns (bool);
    function notify(
        PoolId _poolId,
        bytes4 _key,
        bytes calldata _data
    ) external;
    function poolIndex(
        PoolId _poolId
    ) external view returns (address flaunch_, address memecoin_, address memecoinTreasury_, uint tokenId_);
    function addIndex(
        AddIndexParams[] calldata _params
    ) external;
    function setNotifierFlaunch(
        address _notifier,
        address _flaunch
    ) external;
    function addVerifiedFlaunch(
        address _flaunch
    ) external;
    function removeVerifiedFlaunch(
        address _flaunch
    ) external;
    function isVerifiedFlaunch(
        address _flaunch
    ) external view returns (bool verified_);
}
