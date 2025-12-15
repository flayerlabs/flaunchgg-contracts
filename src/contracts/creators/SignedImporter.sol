// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';


/**
 * This contract allows users to import their memecoin to the AnyPositionManager. When importing
 * a memecoin, we will verify that the creator of the memecoin is authorized by a trusted signer.
 */
contract SignedImporter is Ownable {

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

    event AnyPositionManagerSet(address indexed _anyPositionManager);
    event TrustedSignerUpdated(address indexed _signer, bool _isTrusted);
    event TokenImported(address indexed _memecoin, address indexed _verifier);

    /**
     * This struct is used to store and represent the signed message.
     * 
     * @param token The address of the token to verify
     * @param creator The address of the creator to verify
     * @param deadline The deadline of the signed message
     * @param signature The signature of the signed message
     */
    struct SignedMessage {
        address token;
        address creator;
        uint deadline;
        bytes signature;
    }

    /// Stores the trusted signers that we can validate against
    EnumerableSet.AddressSet internal _trustedSigners;

    /// The AnyPositionManager contract
    AnyPositionManager public anyPositionManager;

    /// Stores the signatures that have been used
    mapping (bytes32 _signature => bool _used) internal _usedSignatures;

    /**
     * Sets the required contract addresses and the owner of the contract.
     *
     * @param _anyPositionManager The address of the AnyPositionManager contract
     */
    constructor (address payable _anyPositionManager) {
        _initializeOwner(msg.sender);

        // Validate and set the AnyPositionManager contract
        setAnyPositionManager(_anyPositionManager);
    }

    /**
     * Initializes a non-native memecoin onto Flaunch.
     *
     * @param _creatorFeeAllocation The percentage of the fee to allocate to the creator
     * @param _initialMarketCap The initial market cap of the memecoin in USDC
     * @param _verificationData abi encoded SignedMessage
     */
    function initialize(uint24 _creatorFeeAllocation, uint _initialMarketCap, bytes memory _verificationData) public {
        // Verify signature & check that the caller is the creator
        address memecoin =_verifySignature(_verificationData);

        // Ensure that the memecoin is not a zero address
        if (memecoin == address(0)) {
            revert ZeroAddress();
        }

        // Flaunch our token into the AnyPositionManager
        anyPositionManager.flaunch(
            AnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: msg.sender,
                creatorFeeAllocation: _creatorFeeAllocation,
                initialPriceParams: abi.encode(_initialMarketCap, memecoin),
                feeCalculatorParams: abi.encode('')
            })
        );

        emit TokenImported(memecoin, address(this));
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
     * Set the AnyPositionManager contract.
     *
     * @param _anyPositionManager The address of the AnyPositionManager contract
     */
    function setAnyPositionManager(address payable _anyPositionManager) public onlyOwner {
        // Ensure that our required contracts are not the zero address
        if (_anyPositionManager == address(0)) revert ZeroAddress();

        // Set the AnyPositionManager contract
        anyPositionManager = AnyPositionManager(_anyPositionManager);
        emit AnyPositionManagerSet(_anyPositionManager);
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
    function _verifySignature(bytes memory _verificationData) internal returns (address memecoin_) {
        (SignedMessage memory signedMessage) = abi.decode(_verificationData, (SignedMessage));

        // Verify the deadline is not expired
        if (block.timestamp > signedMessage.deadline) {
            revert DeadlineExpired(signedMessage.deadline);
        }

        // Verify that the signed creator matches the caller
        if (signedMessage.creator != msg.sender) {
            revert InvalidCaller();
        }

        // Generate the message hash for (token, creator, deadline)
        bytes32 messageHash = keccak256(abi.encodePacked(
            signedMessage.token,
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

        memecoin_ = signedMessage.token;
    }
}
