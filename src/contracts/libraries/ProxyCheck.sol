// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Library for interacting and validating proxy contracts.
 */
library ProxyCheck {
    /**
     * Gets the implementation of a proxy contract by decoding the EIP-1167 minimal proxy pattern.
     *
     * @dev Performs a strict validation of the canonical EIP-1167 runtime bytecode. The target's
     * actual runtime code must be exactly 45 bytes and match both the 10-byte prefix and the
     * 15-byte delegatecall suffix before the implementation address is extracted. If any check
     * fails, the zero address is returned so that callers treat the target as an unrecognised proxy.
     *
     * @param _proxy The address of the proxy contract
     *
     * @return implementation_ The address of the implementation contract, or the zero address if
     * the target is not a canonical EIP-1167 minimal proxy
     */
    function getImplementation(
        address _proxy
    ) internal view returns (address implementation_) {
        // Avoid copying arbitrary-size bytecode into memory. Read size first, then copy only the
        // canonical 45-byte EIP-1167 runtime when it matches.
        uint256 size;
        assembly {
            size := extcodesize(_proxy)
        }
        if (size != 45) {
            return address(0);
        }

        bytes memory code = new bytes(45);
        assembly {
            extcodecopy(_proxy, add(code, 32), 0, 45)
        }

        // Validate the 10-byte prefix (bytes 0-9): 363d3d373d3d3d363d73
        if (
            uint8(code[0]) != 0x36 || uint8(code[1]) != 0x3d || uint8(code[2]) != 0x3d || uint8(code[3]) != 0x37
                || uint8(code[4]) != 0x3d || uint8(code[5]) != 0x3d || uint8(code[6]) != 0x3d || uint8(code[7]) != 0x36
                || uint8(code[8]) != 0x3d || uint8(code[9]) != 0x73
        ) {
            return address(0);
        }

        // Validate the 15-byte delegatecall suffix (bytes 30-44): 5af43d82803e903d91602b57fd5bf3
        if (
            uint8(code[30]) != 0x5a || uint8(code[31]) != 0xf4 || uint8(code[32]) != 0x3d || uint8(code[33]) != 0x82
                || uint8(code[34]) != 0x80 || uint8(code[35]) != 0x3e || uint8(code[36]) != 0x90 || uint8(code[37]) != 0x3d
                || uint8(code[38]) != 0x91 || uint8(code[39]) != 0x60 || uint8(code[40]) != 0x2b || uint8(code[41]) != 0x57
                || uint8(code[42]) != 0xfd || uint8(code[43]) != 0x5b || uint8(code[44]) != 0xf3
        ) {
            return address(0);
        }

        // Extract the 20-byte implementation address from bytes 10-29 (data starts at `code + 32`,
        // so an mload at `code + 30` places bytes 10-29 in the low 20 bytes of the loaded word).
        assembly {
            implementation_ := mload(add(code, 30))
        }
    }
}
