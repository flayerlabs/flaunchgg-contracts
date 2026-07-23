// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {IFeeEscrow} from '@flaunch-interfaces/IFeeEscrow.sol';
import {IIndexerSubscriber} from '@flaunch-interfaces/IIndexerSubscriber.sol';

/**
 * Escrow contract that receives fees from multiple PositionManagers, that allows the recipient
 * to withdraw them in a single transaction.
 */
contract FeeEscrow is IFeeEscrow, Ownable {
    /// The native token address
    address public immutable nativeToken;

    /// The {IndexerSubscriber} subscriber
    IIndexerSubscriber public indexer;

    /// Maps a user to an ETH equivalent token balance available in escrow
    mapping(address _recipient => uint _amount) public balances;

    /// Maps the total fees that a PoolId has accrued
    mapping(PoolId _poolId => uint _amount) public totalFeesAllocated;

    /**
     * Constructor to initialize the PoolSwap contract address.
     *
     * @param _nativeToken The native token used by the Flaunch protocol
     * @param _indexer The {IndexerSubscriber} contract address
     */
    constructor(
        address _nativeToken,
        address _indexer
    ) {
        nativeToken = _nativeToken;
        indexer = IIndexerSubscriber(_indexer);

        _initializeOwner(msg.sender);
    }

    /**
     * Allows a deposit to be made against a user. The amount is stored within the
     * escrow contract to be claimed later.
     *
     * @param _poolId The PoolId that the deposit came from
     * @param _recipient The recipient of the transferred token
     * @param _amount The amount of the token to be transferred
     */
    function allocateFees(
        PoolId _poolId,
        address _recipient,
        uint _amount
    ) external {
        // If we don't have fees to allocate, exit early
        if (_amount == 0) {
            return;
        }

        // Ensure we aren't trying to allocate fees to a zero address
        if (_recipient == address(0)) {
            revert RecipientZeroAddress();
        }

        // Increase the balance available for the recipient to claim
        balances[_recipient] += _amount;

        // Increase the fee tracking for the PoolId, only if the recipient matches the PoolId
        // that has also been passed in. This will prevent users from being misallocated and
        // external contracts that depend on this figure from being misinformed.
        (address flaunch,,, uint tokenId) = indexer.poolIndex(_poolId);
        if (tokenId != 0 && IERC721(flaunch).ownerOf(tokenId) == _recipient) {
            totalFeesAllocated[_poolId] += _amount;
        }

        // Transfer flETH from the sender into this escrow
        IFLETH(nativeToken).transferFrom(msg.sender, address(this), _amount);

        emit Deposit(_poolId, _recipient, nativeToken, _amount);
    }

    /**
     * Allows fees to be withdrawn from escrowed fee positions.
     *
     * @param _recipient The recipient of the holder's withdraw
     * @param _unwrap If we want to unwrap the balance from flETH into ETH
     */
    function withdrawFees(
        address _recipient,
        bool _unwrap
    ) public {
        // Get the amount of token that is stored in escrow
        uint amount = balances[msg.sender];

        // If there are no fees to withdraw, exit early
        if (amount == 0) {
            return;
        }

        // Reset our user's balance to prevent reentry
        balances[msg.sender] = 0;

        // Convert the flETH balance held into native ETH
        if (_unwrap) {
            // Handle a withdraw of the withdrawn ETH
            IFLETH(nativeToken).withdraw(amount);
            (bool _sent,) = payable(_recipient).call{value: amount}('');
            require(_sent, 'ETH Transfer Failed');
            emit Withdrawal(msg.sender, _recipient, address(0), amount);
        }
        // Transfer flETH token without unwrapping
        else {
            SafeTransferLib.safeTransfer(nativeToken, _recipient, amount);
            emit Withdrawal(msg.sender, _recipient, nativeToken, amount);
        }
    }

    /**
     * Allows the owner to update the {IndexerSubscriber}.
     *
     * @param _indexer The new {IndexerSubscriber} contract address
     */
    function setIndexer(
        address _indexer
    ) public onlyOwner {
        indexer = IIndexerSubscriber(_indexer);
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive() external payable {}
}
