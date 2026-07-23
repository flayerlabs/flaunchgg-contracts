// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

interface IFeeEscrow {
    error InvalidRecipient();
    error PoolIdNotIndexed();
    error RecipientZeroAddress();

    event Deposit(PoolId indexed _poolId, address _payee, address _token, uint _amount);
    event Withdrawal(address _sender, address _recipient, address _token, uint _amount);

    function nativeToken() external view returns (address nativeToken_);

    function balances(
        address _recipient
    ) external view returns (uint amount_);

    function totalFeesAllocated(
        PoolId _poolId
    ) external view returns (uint amount_);

    function allocateFees(
        PoolId _poolId,
        address _recipient,
        uint _amount
    ) external;

    function withdrawFees(
        address _recipient,
        bool _unwrap
    ) external;

    function setIndexer(
        address _indexer
    ) external;
}
