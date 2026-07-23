// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {EnumerableSetLib} from '@solady/utils/EnumerableSetLib.sol';

import {IFeeEscrow} from '@flaunch-interfaces/IFeeEscrow.sol';

/**
 * Acts as a middleware for FeeEscrow fee recipients to allow additional control
 * over when fees are claimed and how they are managed.
 */
contract ProtocolFeeRecipient is Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    error EthTransferFailed();

    /// Emitted when a FeeEscrow is enabled or disabled
    event FeeEscrowUpdated(address _feeEscrow, bool _enabled);

    /// The {FeeEscrow}s that will be claimed against
    EnumerableSetLib.AddressSet internal _feeEscrows;

    /**
     * Sets the sender as the owner of the contract.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * The total amount of fees available to be claimed by this contract.
     *
     * @return amount_ The amount of ETH available to claim
     */
    function available() public view returns (uint amount_) {
        // Amount of ETH held in the contract
        amount_ = payable(address(this)).balance;

        // Amount of ETH available to claim from FeeEscrows
        for (uint i; i < _feeEscrows.length(); ++i) {
            amount_ += IFeeEscrow(payable(_feeEscrows.at(i))).balances(address(this));
        }
    }

    /**
     * Claims the available amount to a designated recipient.
     *
     * @param _recipient The recipient of the claimed ETH
     *
     * @return amount_ The amount of ETH received in the claim
     */
    function claim(
        address payable _recipient
    ) public onlyOwner returns (uint amount_) {
        // Withdraw fees from FeeEscrow
        for (uint i; i < _feeEscrows.length(); ++i) {
            IFeeEscrow(payable(_feeEscrows.at(i))).withdrawFees(address(this), true);
        }

        // Find the total amount being claimed by capturing the current ETH balance
        amount_ = payable(address(this)).balance;

        // Transfer all ETH to the recipient
        (bool _sent,) = _recipient.call{value: amount_}('');
        if (!_sent) {
            revert EthTransferFailed();
        }
    }

    /**
     * Sets or removes a FeeEscrow from the internal array.
     *
     * @param _feeEscrow The FeeEscrow to be manipulated in the EnumerableSet
     * @param _enable If the FeeEscrow is being enabled (true) or disabled (false)
     */
    function setFeeEscrow(
        address _feeEscrow,
        bool _enable
    ) public onlyOwner {
        if (_enable && !_feeEscrows.contains(_feeEscrow)) {
            _feeEscrows.add(_feeEscrow);
            emit FeeEscrowUpdated(_feeEscrow, true);
        } else if (!_enable && _feeEscrows.contains(_feeEscrow)) {
            // Withdraw fees before removing
            IFeeEscrow(payable(_feeEscrow)).withdrawFees(address(this), true);

            _feeEscrows.remove(_feeEscrow);
            emit FeeEscrowUpdated(_feeEscrow, false);
        }
    }

    /**
     * Allows the contract to receive ETH from fees.
     */
    receive() external payable {}
}
