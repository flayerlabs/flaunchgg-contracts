// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

/**
 * This contract allows users to deploy CrossChain token for their solana coin, when authorized by a trusted signer.
 * The verifier checks that the sender is the creator of the base token.
 */
contract SolanaVerifier is IImportVerifier, Ownable {

    using EnumerableSet for EnumerableSet.AddressSet;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    error ZeroAddress();
    error InvalidSigner(address _invalidSigner);
    error SignerAlreadyAdded(address _signer);
    error SignerDoesNotExist(address _signer);
    error DeadlineExpired(uint _deadline);
    error InvalidCaller();
    error SignatureAlreadyUsed();
    error BaseTokenAlreadyDeployed(bytes32 _remoteToken);

    event CrossChainERC20FactorySet(address indexed _crossChainERC20Factory);
    event TrustedSignerUpdated(address indexed _signer, bool _isTrusted);
    event BaseTokenDeployed(address indexed _baseToken, bytes32 indexed _remoteToken, address indexed _creator);
    
    /**
     * This struct is used to store and represent the signed message.
     * 
     * @param remoteToken The 32-byte identifier of the corresponding token on solana
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals The number of decimals of the token
     * @param creator The address of the creator to verify
     * @param deadline The deadline of the signed message
     * @param signature The signature of the signed message
     */
    struct SignedMessage {
        bytes32 remoteToken;
        string name;
        string symbol;
        uint8 decimals;
        address creator;
        uint deadline;
        bytes signature;
    }

    /// Stores the trusted signers that we can validate against
    EnumerableSet.AddressSet internal _trustedSigners;

    /// The Base bridge contract
    ICrossChainERC20Factory public crossChainERC20Factory;

    /// Stores the signatures that have been used
    mapping (bytes32 _signature => bool _used) internal _usedSignatures;

    /// Mapping of solana token identifiers to base token addresses
    mapping (bytes32 _remoteToken => address _baseToken) public remoteTokenToBaseToken;
    mapping (address _baseToken => bytes32 _remoteToken) public baseTokenToRemoteToken;
    mapping (address _baseToken => address _creator) public baseTokenToCreator;

    /**
     * Sets the required contract addresses and the owner of the contract.
     *
     * @param _crossChainERC20Factory The address of the CrossChainERC20Factory contract
     */
    constructor (address _crossChainERC20Factory) {
        _initializeOwner(msg.sender);

        // Validate and set the CrossChainERC20Factory contract
        setCrossChainERC20Factory(_crossChainERC20Factory);
    }

    /**
     * Deploys a base token corresponding to the solana token, when authorized by a trusted signer.
     * 
     * @param _verificationData abi encoded SignedMessage
     */
    function deployBaseToken(bytes memory _verificationData) external {
        // Verify signature & check that the caller is the creator
        (bytes32 remoteToken, string memory name, string memory symbol, uint8 decimals) = _verifySignature(_verificationData);

        // Verify that the base token has not already been deployed
        if (remoteTokenToBaseToken[remoteToken] != address(0)) {
            revert BaseTokenAlreadyDeployed(remoteToken);
        }

         // deploy base token corresponding to the solana token
        address baseToken = crossChainERC20Factory.deploy(remoteToken, name, symbol, decimals);

        // Ensure that the baseToken is not a zero address
        if (baseToken == address(0)) {
            revert ZeroAddress();
        }

        // update mappings
        remoteTokenToBaseToken[remoteToken] = baseToken;
        baseTokenToRemoteToken[baseToken] = remoteToken;
        baseTokenToCreator[baseToken] = msg.sender;

        emit BaseTokenDeployed(baseToken, remoteToken, msg.sender);
    }

    /**
     * Checks if the sender is the creator of the base token.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the sender is the creator of the base token, false otherwise
     */
    function isValid(address _token, address _sender) public view returns (bool) {
        return baseTokenToCreator[_token] == _sender;
    }

    /**
     * Set the CrossChainERC20Factory contract.
     *
     * @param _crossChainERC20Factory The address of the CrossChainERC20Factory contract
     */
    function setCrossChainERC20Factory(address _crossChainERC20Factory) public onlyOwner {
        // Ensure that our required contracts are not the zero address
        if (_crossChainERC20Factory == address(0)) revert ZeroAddress();

        // Set the CrossChainERC20Factory contract
        crossChainERC20Factory = ICrossChainERC20Factory(_crossChainERC20Factory);
        emit CrossChainERC20FactorySet(_crossChainERC20Factory);
    }

    /**
     * Adds a signer to the trusted signers list.
     * 
     * @param _signer The address to add as a trusted signer
     */
    function addTrustedSigner(address _signer) external onlyOwner {
        // Verify that the signer is not the zero address
        if (_signer == address(0)) {
            revert InvalidSigner(_signer);
        }

        // Verify that the signer is not already in the list. If this call returns `true` then it
        // will have been added successfully.
        if (!_trustedSigners.add(_signer)) {
            revert SignerAlreadyAdded(_signer);
        }
        
        emit TrustedSignerUpdated(_signer, true);
    }

    /**
     * Removes a signer from the trusted signers list.
     * 
     * @param _signer The address to remove as a trusted signer
     */
    function removeTrustedSigner(address _signer) external onlyOwner {
        if (!_trustedSigners.remove(_signer)) {
            revert SignerDoesNotExist(_signer);
        }

        emit TrustedSignerUpdated(_signer, false);
    }

    /**
     * Get all trusted signers that are used to verify memecoins.
     * 
     * @return signers_ Array of all registered signer addresses
     */
    function getAllTrustedSigners() public view returns (address[] memory signers_) {
        signers_ = _trustedSigners.values();
    }

    /**
     * Checks if an address is a trusted signer.
     * 
     * @param _signer The address to check
     *
     * @return valid_ `True` if the address is a trusted signer, `false` otherwise
     */
    function isTrustedSigner(address _signer) public view returns (bool valid_) {
        valid_ = _trustedSigners.contains(_signer);
    }

    /**
     * @dev Internal function to verify a signed message against trusted signers.
     *
     * @param _verificationData abi encoded SignedMessage
     */
    function _verifySignature(bytes memory _verificationData) 
        internal 
        returns (bytes32 remoteToken_, string memory name_, string memory symbol_, uint8 decimals_)
    {
        (SignedMessage memory signedMessage) = abi.decode(_verificationData, (SignedMessage));

        // Verify the deadline is not expired
        if (block.timestamp > signedMessage.deadline) {
            revert DeadlineExpired(signedMessage.deadline);
        }

        // Verify that the signed creator matches the caller
        if (signedMessage.creator != msg.sender) {
            revert InvalidCaller();
        }

        // Generate the message hash for (remoteToken, name, symbol, decimals, creator, deadline)
        bytes32 messageHash = keccak256(abi.encodePacked(
            signedMessage.remoteToken,
            signedMessage.name,
            signedMessage.symbol,
            signedMessage.decimals,
            msg.sender,
            signedMessage.deadline
        ));

        // Generate the message hash
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        if (_usedSignatures[ethSignedMessageHash]) {
            revert SignatureAlreadyUsed();
        }

        // Recover the signer and confirm that it is a trusted signer
        (address recoveredSigner,,) = ethSignedMessageHash.tryRecover(signedMessage.signature);
        if (!isTrustedSigner(recoveredSigner)) {
            revert InvalidSigner(recoveredSigner);
        }

        // Mark the signature as used
        _usedSignatures[ethSignedMessageHash] = true;

        remoteToken_ = signedMessage.remoteToken;
        name_ = signedMessage.name;
        symbol_ = signedMessage.symbol;
        decimals_ = signedMessage.decimals;
    }
}

interface ICrossChainERC20Factory {
    function deploy(bytes32 remoteToken, string memory name, string memory symbol, uint8 decimals) external returns (address);
}