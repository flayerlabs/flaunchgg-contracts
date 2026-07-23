// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';

import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';

/**
 * This contract will allow for specific addresses to have reduced or nullified fees for all
 * swaps transactions within the pool. These will be allocated to partners that need a more
 * consistent underlying price to ensure their protocol can operate using Flaunch pools.
 */
contract FeeExemptions is IFeeExemptions, Ownable {
    using LPFeeLibrary for uint24;

    /// Stores a mapping of beneficiaries and that flat fee exemptions
    mapping(address _beneficiary => FeeExemption _exemption) internal _feeExemption;

    /**
     * Registers the caller as the contract owner.
     *
     * @param _protocolOwner The initial EOA owner of the contract
     */
    constructor(
        address _protocolOwner
    ) {
        // Grant ownership permissions to the caller
        _initializeOwner(_protocolOwner);
    }

    /**
     * Gets the `FeeExemption` data struct for a beneficiary address.
     *
     * @param _beneficiary The address of the beneficiary
     *
     * @return The FeeExemption struct for the beneficiary
     */
    function feeExemption(
        address _beneficiary
    ) public view returns (FeeExemption memory) {
        return _feeExemption[_beneficiary];
    }

    /**
     * Set our beneficiary's flat fee rate across all pools. If a beneficiary is set, then
     * the fee processed during a swap will be overwritten if this fee exemption value is
     * lower than the otherwise determined fee.
     *
     * @param _beneficiary The swap `sender` that will receive the exemption
     * @param _flatFee The flat fee value that the `_beneficiary` will receive
     */
    function setFeeExemption(
        address _beneficiary,
        uint24 _flatFee
    ) public onlyOwner {
        // Ensure that our custom fee conforms to Uniswap V4 requirements
        if (!_flatFee.isValid()) {
            revert FeeExemptionInvalid(_flatFee, LPFeeLibrary.MAX_LP_FEE);
        }

        _feeExemption[_beneficiary] = FeeExemption(_flatFee, true);
        emit BeneficiaryFeeSet(_beneficiary, _flatFee);
    }

    /**
     * Removes a beneficiary fee exemption.
     *
     * @dev If the `beneficiary` does not already have an exemption, this call will revert.
     *
     * @param _beneficiary The address to remove the fee exemption from
     */
    function removeFeeExemption(
        address _beneficiary
    ) public onlyOwner {
        // Check that a beneficiary is currently enabled
        if (!_feeExemption[_beneficiary].enabled) {
            revert NoBeneficiaryExemption(_beneficiary);
        }

        delete _feeExemption[_beneficiary];
        emit BeneficiaryFeeRemoved(_beneficiary);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
