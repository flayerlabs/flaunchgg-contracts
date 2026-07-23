// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

contract FlaunchFeeExemption is Ownable {
    event FeeExemptionUpdated(address indexed _beneficiary, bool _excluded);

    /// Stores the mapping for fee exclusions
    mapping(address _beneficiary => bool _excluded) public feeExcluded;

    /**
     * Initialize the contract owner as the sender.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * Allows the contract owner to set a fee exclusion.
     *
     * @param _beneficiary The address to be updated
     * @param _excluded If the address is excluded from fees (`true`) or should pay fees (`false`)
     */
    function setFeeExemption(
        address _beneficiary,
        bool _excluded
    ) public onlyOwner {
        feeExcluded[_beneficiary] = _excluded;
        emit FeeExemptionUpdated(_beneficiary, _excluded);
    }
}
