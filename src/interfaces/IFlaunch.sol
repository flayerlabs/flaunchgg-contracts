// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

interface IFlaunch {
    error CallerIsNotPositionManager();
    error CreatorFeeAllocationInvalid(uint24 _allocation, uint _maxAllocation);
    error InvalidFlaunchSchedule();
    error InvalidInitialSupply(uint _initialSupply);

    event BaseURIUpdated(string _newBaseURI);
    event MemecoinImplementationUpdated(address _newImplementation);
    event MemecoinTreasuryImplementationUpdated(address _newImplementation);

    struct TokenInfo {
        address memecoin;
        address payable memecoinTreasury;
    }

    function initialize(
        IPositionManager _positionManager,
        address _memecoinTreasuryImplementation
    ) external;

    function flaunch(
        IPositionManager.FlaunchParams calldata
    ) external returns (address memecoin_, address payable memecoinTreasury_, uint tokenId_);

    function tokenId(
        address _memecoin
    ) external view returns (uint tokenId_);

    function memecoin(
        uint _tokenId
    ) external view returns (address memecoin_);

    function memecoinTreasury(
        uint _tokenId
    ) external view returns (address payable memecoinTreasury_);

    function poolId(
        uint _tokenId
    ) external view returns (PoolId poolId_);

    function burn(
        uint _tokenId
    ) external;
}
