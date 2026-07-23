// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

interface IReferralEscrow {
    error MismatchedTokensAndLimits();
    error NotPositionManager();

    event TokensAssigned(PoolId indexed _poolId, address indexed _user, address indexed _token, uint _amount);
    event TokensClaimed(address indexed _user, address _recipient, address indexed _token, uint _amount);

    function allocations(
        address _user,
        address _token
    ) external view returns (uint _amount);
    function nativeToken() external view returns (address);
    function setPoolSwap(
        address _poolSwap
    ) external;
    function assignTokens(
        PoolId _poolId,
        address _user,
        address _token,
        uint _amount
    ) external;
    function claimTokens(
        address[] calldata _tokens,
        address payable _recipient
    ) external;
}
