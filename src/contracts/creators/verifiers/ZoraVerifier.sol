// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {ProxyCheck} from '@flaunch/libraries/ProxyCheck.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * Interface for the Zora Coin contract.
 */
interface IZoraCoin {
    function payoutRecipient() external view returns (address);
}

/**
 * Confirms that a memecoin has been defined in the Zora Airlock.
 */
contract ZoraVerifier is IImportVerifier, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    error ZeroAddress();
    error NotAContract();

    event ZoraCoinImplementationSet(address indexed _zoraCoinImplementation, bool _valid);

    /// The Zora token implementation contract
    EnumerableSet.AddressSet internal _zoraCoinImplementations;

    /**
     * Registers the Zora token implementation contract.
     */
    constructor() {
        // Set the owner to the deployer
        _initializeOwner(msg.sender);
    }

    /**
     * Checks if a token was deployed from a supported Zora Coin implementation.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the token is a Zora token, false otherwise
     */
    function isValid(
        address _token,
        address _sender
    ) public view returns (bool) {
        // If the token is not a Zora token, then it is not valid
        if (!_zoraCoinImplementations.contains(ProxyCheck.getImplementation(_token))) {
            return false;
        }

        // Bind to the canonical `payoutRecipient` (the address that receives the coin's creator
        // earnings) rather than ANY co-owner. A Zora coin can have multiple owners; accepting any
        // `isOwner` (the previous behaviour) let a non-creator co-owner capture the imported fee
        // NFT (F-7). The payout recipient is the authoritative economic creator of the coin.
        return IZoraCoin(_token).payoutRecipient() == _sender;
    }

    /**
     * Sets or removes a Zora coin implementation address.
     *
     * @param _zoraCoinImplementation The address of the Zora coin implementation
     * @param _valid Whether the implementation is valid
     */
    function setZoraCoinImplementation(
        address _zoraCoinImplementation,
        bool _valid
    ) external onlyOwner {
        // Ensure that the Zora coin implementation is not a zero address
        if (_zoraCoinImplementation == address(0)) {
            revert ZeroAddress();
        }

        // Provenance hardening (F-8): only whitelist implementations that are actually deployed
        // contracts. This blocks whitelisting EOAs / undeployed addresses.
        // ACCEPTED RESIDUAL: a permissionless self-deployed clone of a whitelisted implementation is
        // byte-identical, so this cannot fully prevent forged provenance without a registry/signer gate.
        if (_valid && _zoraCoinImplementation.code.length == 0) {
            revert NotAContract();
        }

        // Add or remove the Zora coin implementation
        if (_valid) {
            _zoraCoinImplementations.add(_zoraCoinImplementation);
        } else {
            _zoraCoinImplementations.remove(_zoraCoinImplementation);
        }

        emit ZoraCoinImplementationSet(_zoraCoinImplementation, _valid);
    }
}
