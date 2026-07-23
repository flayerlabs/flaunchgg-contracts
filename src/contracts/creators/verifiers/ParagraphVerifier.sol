// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

interface IUniswapV4MulticurveInitializer {
    struct BeneficiaryData {
        address beneficiary;
        uint96 shares;
    }

    function getBeneficiaries(
        address asset
    ) external view returns (BeneficiaryData[] memory);
}

/**
 * Confirms that a memecoin has been deployed on Paragraph.
 */
contract ParagraphVerifier is IImportVerifier {
    /// The Paragraph contract
    IUniswapV4MulticurveInitializer public immutable paragraph;

    /**
     * Registers the Paragraph contract.
     *
     * @param _paragraph The address of the Paragraph contract
     */
    constructor(
        address _paragraph
    ) {
        paragraph = IUniswapV4MulticurveInitializer(_paragraph);
    }

    /**
     * Checks if a token exists on Paragraph.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the token exists on Paragraph, false otherwise
     */
    function isValid(
        address _token,
        address _sender
    ) public view returns (bool) {
        // Confirm that the token is deployed on Paragraph
        IUniswapV4MulticurveInitializer.BeneficiaryData[] memory beneficiaries = paragraph.getBeneficiaries(_token);
        if (beneficiaries.length == 0) {
            return false;
        }

        // Bind to the PRIMARY (largest-share) beneficiary rather than ANY beneficiary. Paragraph
        // launches include low-share protocol/platform fee beneficiaries; accepting any beneficiary
        // (the previous behaviour) let those non-creators capture the imported fee NFT (F-7). We pick
        // the beneficiary with the greatest share, keeping the first one seen on a tie.
        // RESIDUAL (F-7): co-creators that split the top share equally (and all lower-share
        // beneficiaries) cannot import; only the first top-share beneficiary is authorised.
        uint primaryIndex;
        for (uint i = 1; i < beneficiaries.length; ++i) {
            if (beneficiaries[i].shares > beneficiaries[primaryIndex].shares) {
                primaryIndex = i;
            }
        }

        return beneficiaries[primaryIndex].beneficiary == _sender;
    }
}
