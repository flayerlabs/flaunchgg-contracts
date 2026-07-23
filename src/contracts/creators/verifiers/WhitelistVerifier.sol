// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * Verifier that checks if a sender is whitelisted for a specific memecoin.
 */
contract WhitelistVerifier is IImportVerifier, Ownable {
    error ZeroAddress();

    event WhitelistUpdated(address indexed _sender, address indexed _memecoin);

    // Mapping from memecoin address to sender address to whitelist status
    mapping(address _memecoin => address _sender) public whitelist;

    /**
     * Sets the owner of the contract to the deployer.
     */
    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * Set a whitelisted sender for a specific memecoin.
     *
     * @param _sender The address to whitelist
     * @param _memecoin The memecoin address
     */
    function setWhitelist(
        address _sender,
        address _memecoin
    ) public onlyOwner {
        // Ensure that the memecoin is not a zero address. We allow for a zero address sender as
        // this is used to remove the memecoin from the whitelist.
        if (_memecoin == address(0)) {
            revert ZeroAddress();
        }

        // Update the whitelist
        whitelist[_memecoin] = _sender;
        emit WhitelistUpdated(_sender, _memecoin);
    }

    /**
     * Check if a sender is whitelisted for a specific memecoin.
     *
     * @param _memecoin The memecoin address
     * @param _sender The sender of the transaction
     *
     * @return bool True if the sender is whitelisted for the memecoin, false otherwise
     */
    function isValid(
        address _memecoin,
        address _sender
    ) public view override returns (bool) {
        return whitelist[_memecoin] == _sender;
    }
}
