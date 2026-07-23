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

    function deploymentInfoForToken(
        address token
    ) external view returns (DeploymentInfo memory);
}

interface IClankerToken {
    function admin() external view returns (address);
    function deployer() external view returns (address);
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
    constructor() {
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
    function isValid(
        address _token,
        address _sender
    ) public view returns (bool isValid_) {
        // Iterate over our known factories and confirm that the token address is recognised on one of them
        uint numFactories = _clankerFactories.length();
        for (uint i; i < numFactories; ++i) {
            if (IClanker(_clankerFactories.at(i)).deploymentInfoForToken(_token).token != address(0)) {
                isValid_ = true;
                break;
            }
        }

        // If we could validate the token on a known factory, then confirm that the sender is the
        // authoritative creator of the token. Clanker v1.x exposes `admin()` whereas Clanker
        // v2.0.0/v3.0.0 tokens expose `deployer()` (and revert on `admin()`), so we probe both
        // defensively via low-level staticcalls and never let a missing/reverting getter DoS the
        // import or the TokenImporter auto-verify loop.
        isValid_ = isValid_ && _isAuthorisedCreator(_token, _sender);
    }

    /**
     * Revert-safe, version-aware check that `_sender` is the authoritative creator of `_token`.
     * Tries `admin()` (Clanker v1.x) then falls back to `deployer()` (Clanker v2/v3). Returns
     * false if neither getter is present, reverts, or resolves to an address other than `_sender`.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return True if the sender is the token's creator, false otherwise
     */
    function _isAuthorisedCreator(
        address _token,
        address _sender
    ) internal view returns (bool) {
        // Try `admin()` first (Clanker v1.x)
        (bool success, bytes memory data) = _token.staticcall(abi.encodeCall(IClankerToken.admin, ()));
        if (success && data.length == 32 && _toAddress(data) == _sender) {
            return true;
        }

        // Fall back to `deployer()` (Clanker v2.0.0/v3.0.0)
        (success, data) = _token.staticcall(abi.encodeCall(IClankerToken.deployer, ()));
        if (success && data.length == 32 && _toAddress(data) == _sender) {
            return true;
        }

        return false;
    }

    /**
     * Decodes a 32-byte return value into an address by truncating to the low 160 bits. Unlike
     * `abi.decode`, this never reverts on dirty upper bits, keeping the verifier revert-safe against
     * adversarial return data.
     *
     * @param _data The 32-byte return data
     *
     * @return addr_ The decoded address
     */
    function _toAddress(
        bytes memory _data
    ) internal pure returns (address addr_) {
        assembly {
            addr_ := and(mload(add(_data, 32)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /**
     * Sets or removes a Clanker factory address.
     *
     * @param _clankerFactory The address of the Clanker factory
     * @param _valid Whether the factory is valid
     */
    function setClankerFactory(
        address _clankerFactory,
        bool _valid
    ) external onlyOwner {
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
