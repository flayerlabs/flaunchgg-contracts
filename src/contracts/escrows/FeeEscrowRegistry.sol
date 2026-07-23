// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {EnumerableSetLib} from '@solady/utils/EnumerableSetLib.sol';

import {IFeeEscrow} from '@flaunch-interfaces/IFeeEscrow.sol';
import {IFeeEscrowRegistry} from '@flaunch-interfaces/IFeeEscrowRegistry.sol';

/**
 * Registry contract that stores a list of all valid {FeeEscrow} contracts.
 */
contract FeeEscrowRegistry is IFeeEscrowRegistry, Ownable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// Store an internal list of all valid {FeeEscrow} contracts
    EnumerableSetLib.AddressSet internal _feeEscrows;

    /// Mapping to flag a FeeEscrow as "legacy", which will change the interface callable
    mapping(address _feeEscrow => bool _legacy) internal _legacy;

    /**
     * Sets the caller as the owner of the contract.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * Returns the list of all valid {FeeEscrow} contracts.
     *
     * @return feeEscrows_ The list of all valid {FeeEscrow} contracts
     */
    function feeEscrows() public view returns (address[] memory feeEscrows_) {
        feeEscrows_ = _feeEscrows.values();
    }

    /**
     * Returns whether a {FeeEscrow} contract is legacy.
     *
     * @param _feeEscrow The {FeeEscrow} contract to check
     *
     * @return bool True if the {FeeEscrow} contract is legacy, false otherwise
     */
    function isLegacy(
        address _feeEscrow
    ) public view returns (bool) {
        return _legacy[_feeEscrow];
    }

    /**
     * Sets or removes a {FeeEscrow} contract from the internal list.
     *
     * @param _feeEscrow The {FeeEscrow} contract to be added to the EnumerableSet
     */
    function addFeeEscrow(
        address _feeEscrow,
        bool _isLegacy
    ) public onlyOwner {
        if (_feeEscrows.add(_feeEscrow)) {
            _legacy[_feeEscrow] = _isLegacy;
            emit FeeEscrowAdded(_feeEscrow, _isLegacy);
        }
    }

    /**
     * Removes a {FeeEscrow} contract from the internal list.
     *
     * @param _feeEscrow The {FeeEscrow} contract to be removed from the EnumerableSet
     */
    function removeFeeEscrow(
        address _feeEscrow
    ) public onlyOwner {
        if (_feeEscrows.remove(_feeEscrow)) {
            delete _legacy[_feeEscrow];
            emit FeeEscrowRemoved(_feeEscrow);
        }
    }
}
