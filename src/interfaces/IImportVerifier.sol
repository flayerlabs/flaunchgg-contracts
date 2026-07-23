// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * This interface defines the function that verifies if a token is valid to be bridged.
 */
interface IImportVerifier {
    /**
     * Checks if a token is valid to be bridged.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the token is valid, false otherwise
     */
    function isValid(
        address _token,
        address _sender
    ) external view returns (bool);
}
