// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * A mock implementation of the IImportVerifier interface that allows us to set the
 * result of the isValid function for testing purposes.
 */
contract ImportVerifierMock is IImportVerifier {
    /// Whether the verifier should return a valid result
    bool public shouldReturnValid;

    /**
     * Set the result of the isValid function.
     *
     * @param _shouldReturnValid Whether the verifier should return a valid result
     */
    function setIsValid(
        bool _shouldReturnValid
    ) public {
        shouldReturnValid = _shouldReturnValid;
    }

    /**
     * @inheritdoc IImportVerifier
     */
    function isValid(
        address,
        address
    ) external view returns (bool) {
        return shouldReturnValid;
    }
}
