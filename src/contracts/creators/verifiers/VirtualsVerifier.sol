// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {ProxyCheck} from '@flaunch/libraries/ProxyCheck.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * Interface for the Virtuals AgentToken contract.
 */
interface IAgentToken {
    function owner() external view returns (address owner_);
}

/**
 * Confirms that a memecoin is a Virtuals AgentToken. For an AgentToken to be valid, it must have been
 * successfully launched and deployed on the Virtuals platform, and the sender must be the owner of the
 * AgentToken on the contract.
 */
contract VirtualsVerifier is IImportVerifier, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    error ZeroAddress();
    error NotAContract();

    event AgentTokenImplementationSet(address indexed _agentTokenImplementation, bool _valid);

    /// The VirtualsAgentToken implementation contract
    EnumerableSet.AddressSet internal _agentTokenImplementations;

    /**
     * Registers the contract owner.
     */
    constructor() {
        // Set the owner to the deployer
        _initializeOwner(msg.sender);
    }

    /**
     * Checks if a token was deployed from a supported Virtuals AgentToken implementation.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the token is a Virtuals AgentToken, false otherwise
     */
    function isValid(
        address _token,
        address _sender
    ) public view returns (bool) {
        // If the token is not a Virtuals AgentToken, then it is not valid
        if (!_agentTokenImplementations.contains(ProxyCheck.getImplementation(_token))) {
            return false;
        }

        // Confirm that the sender is an owner of the AgentToken
        return IAgentToken(_token).owner() == _sender;
    }

    /**
     * Sets or removes a Virtuals AgentToken implementation address.
     *
     * @param _agentTokenImplementation The address of the AgentToken implementation
     * @param _valid Whether the implementation is valid
     */
    function setAgentTokenImplementation(
        address _agentTokenImplementation,
        bool _valid
    ) external onlyOwner {
        // Ensure that the AgentToken implementation is not a zero address
        if (_agentTokenImplementation == address(0)) {
            revert ZeroAddress();
        }

        // Provenance hardening (F-8): only whitelist implementations that are actually deployed
        // contracts. This blocks whitelisting EOAs / undeployed addresses.
        // ACCEPTED RESIDUAL: a permissionless self-deployed clone of a whitelisted implementation is
        // byte-identical, so this cannot fully prevent forged provenance without a registry/signer gate.
        if (_valid && _agentTokenImplementation.code.length == 0) {
            revert NotAContract();
        }

        // Add or remove the AgentToken implementation
        if (_valid) {
            _agentTokenImplementations.add(_agentTokenImplementation);
        } else {
            _agentTokenImplementations.remove(_agentTokenImplementation);
        }

        emit AgentTokenImplementationSet(_agentTokenImplementation, _valid);
    }
}
