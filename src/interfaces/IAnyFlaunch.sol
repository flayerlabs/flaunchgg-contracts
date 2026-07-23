// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {IAnyPositionManager} from '@flaunch-interfaces/IAnyPositionManager.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

interface IAnyFlaunch {
    error BaseURICannotBeEmpty();
    error CallerIsNotPositionManager();
    error CreatorFeeAllocationInvalid(uint24 _allocation, uint _maxAllocation);

    event BaseURIUpdated(string _newBaseURI);
    event MemecoinTreasuryImplementationUpdated(address _newImplementation);

    struct TokenInfo {
        address memecoin;
        address payable memecoinTreasury;
    }

    function initialize(
        IAnyPositionManager _positionManager,
        address _memecoinTreasuryImplementation
    ) external;

    function tokenId(
        address _memecoin
    ) external view returns (uint tokenId_);

    function flaunch(
        IAnyPositionManager.FlaunchParams calldata
    ) external returns (address payable memecoinTreasury_, uint tokenId_);

    function creator(
        address _memecoin
    ) external view returns (address creator_);

    function memecoinTreasury(
        address _memecoin
    ) external view returns (address payable memecoinTreasury_);

    function memecoinTreasury(
        uint _tokenId
    ) external view returns (address payable memecoinTreasury_);

    function memecoin(
        uint _tokenId
    ) external view returns (address memecoin_);

    function poolId(
        uint _tokenId
    ) external view returns (PoolId poolId_);

    function burn(
        uint _tokenId
    ) external;
}
