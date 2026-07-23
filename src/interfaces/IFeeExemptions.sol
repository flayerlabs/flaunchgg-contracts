// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeeExemptions {
    error FeeExemptionInvalid(uint24 _invalidFee, uint24 _maxFee);
    error NoBeneficiaryExemption(address _beneficiary);

    event BeneficiaryFeeSet(address _beneficiary, uint24 _flatFee);
    event BeneficiaryFeeRemoved(address _beneficiary);

    struct FeeExemption {
        uint24 flatFee;
        bool enabled;
    }

    function feeExemption(
        address _beneficiary
    ) external view returns (FeeExemption memory);
    function setFeeExemption(
        address _beneficiary,
        uint24 _flatFee
    ) external;
    function removeFeeExemption(
        address _beneficiary
    ) external;
}
