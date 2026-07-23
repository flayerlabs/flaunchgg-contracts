// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * Interface for the MockERC20Factory contract.
 */
interface IMockERC20Factory {
    function deployedTokens(
        address _token
    ) external view returns (bool exists_);
}

/**
 * Confirms that a memecoin was deployed by the MockERC20Factory.
 */
contract MockERC20Verifier is IImportVerifier {
    /// The MockERC20Factory contract
    IMockERC20Factory public immutable mockERC20Factory;

    /**
     * Sets the MockERC20Factory contract address.
     *
     * @param _mockERC20Factory The address of the MockERC20Factory contract
     */
    constructor(
        address _mockERC20Factory
    ) {
        mockERC20Factory = IMockERC20Factory(_mockERC20Factory);
    }

    /**
     * Checks if a token was deployed by the MockERC20Factory.
     *
     * @param _token The address of the token to verify
     *
     * @return bool True if the token was deployed by the MockERC20Factory, false otherwise
     */
    function isValid(
        address _token,
        address /* _sender */
    ) public view returns (bool) {
        // If the token was deployed by the MockERC20Factory, then it is valid
        return mockERC20Factory.deployedTokens(_token);
    }
}
