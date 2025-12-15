// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';


interface IClanker {

    struct DeploymentInfo {
        address token;
        uint positionId;
        address locker;
    }

    function deploymentInfoForToken(address token) external view returns (DeploymentInfo memory);

}

interface IClankerToken {
    function admin() external view returns (address);
}


/**
 * Confirms that a memecoin has been deployed via one of the known Clanker factories.
 */
contract ClankerWorldVerifier is IImportVerifier, Ownable {

    using EnumerableSet for EnumerableSet.AddressSet;

    error ZeroAddress();

    event ClankerFactorySet(address indexed _clankerFactory, bool _valid);

    /// The Clanker factories
    EnumerableSet.AddressSet internal _clankerFactories;

    /**
     * Registers the owner of the contract.
     */
    constructor () {
        // Set the owner to the deployer
        _initializeOwner(msg.sender);
    }

    /**
     * Checks if a token exists on a known Clanker factory and that the sender is the admin of the token.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return isValid_ True if the token is valid, false otherwise
     */
    function isValid(address _token, address _sender) public view returns (bool isValid_) {
        // Iterate over our known factories and confirm that the token address is recognised on one of them
        uint numFactories = _clankerFactories.length();
        for (uint i; i < numFactories; ++i) {
            if (IClanker(_clankerFactories.at(i)).deploymentInfoForToken(_token).token != address(0)) {
                isValid_ = true;
                break;
            }
        }

        // If we could validate the token on a known factory, then confirm that the sender is the original
        // creator of the token.
        isValid_ = isValid_ && IClankerToken(_token).admin() == _sender;
    }

    /**
     * Sets or removes a Clanker factory address.
     *
     * @param _clankerFactory The address of the Clanker factory
     * @param _valid Whether the factory is valid
     */
    function setClankerFactory(address _clankerFactory, bool _valid) external onlyOwner {
        // Ensure that the Clanker factory is not a zero address
        if (_clankerFactory == address(0)) {
            revert ZeroAddress();
        }

        // Add or remove the Clanker factory
        if (_valid) {
            _clankerFactories.add(_clankerFactory);
        } else {
            _clankerFactories.remove(_clankerFactory);
        }

        emit ClankerFactorySet(_clankerFactory, _valid);
    }

}