// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SignedImporter} from '@flaunch/creators/SignedImporter.sol';
import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract SignedImporterTest is FlaunchTest {

    SignedImporter public importer;

    address public constant TEST_TOKEN = address(0x123);
    uint24 public constant TEST_CREATOR_FEE_ALLOCATION = 80_00;
    uint public constant TEST_INITIAL_MARKET_CAP = 5000e6;
    
    /// The signer we will be using for tests
    address internal signer;
    uint internal signerPrivateKey;

    /// Another signer for multi-signer tests
    address internal signer2;
    uint internal signerPrivateKey2;

    function setUp() public {
        _deployPlatform();

        // Deploy the SignedImporter
        importer = new SignedImporter(payable(address(anyPositionManager)));

        // Approve the importer against the AnyPositionManager
        anyPositionManager.approveCreator(address(importer), true);

        // Setup signers
        (signer, signerPrivateKey) = makeAddrAndKey('signer');
        (signer2, signerPrivateKey2) = makeAddrAndKey('signer2');
    }

    // ============ Constructor Tests ============

    function test_CannotDeployWithZeroAddress() public {
        vm.expectRevert(SignedImporter.ZeroAddress.selector);
        new SignedImporter(payable(address(0)));
    }

    function test_CanDeployWithValidAnyPositionManager() public {
        SignedImporter newImporter = new SignedImporter(payable(address(anyPositionManager)));
        assertEq(address(newImporter.anyPositionManager()), address(anyPositionManager));
        assertEq(newImporter.owner(), address(this));
    }

    // ============ Trusted Signer Management Tests ============

    function test_CanAddTrustedSigner() public {
        // Confirm that the signer is not already in the list
        assertFalse(importer.isTrustedSigner(signer));

        // Add trusted signer
        vm.expectEmit();
        emit SignedImporter.TrustedSignerUpdated(signer, true);
        importer.addTrustedSigner(signer);

        // Confirm that the signer is now in the list
        assertTrue(importer.isTrustedSigner(signer));

        // Verify it appears in the list of all signers
        address[] memory signers = importer.getAllTrustedSigners();
        assertEq(signers.length, 1);
        assertEq(signers[0], signer);
    }

    function test_CannotAddZeroAddressTrustedSigner() public {
        vm.expectRevert(abi.encodeWithSelector(SignedImporter.InvalidSigner.selector, address(0)));
        importer.addTrustedSigner(address(0));
    }

    function test_CannotAddDuplicateTrustedSigner() public {
        // Add signer first
        importer.addTrustedSigner(signer);

        // Try to add the same signer again
        vm.expectRevert(abi.encodeWithSelector(SignedImporter.SignerAlreadyAdded.selector, signer));
        importer.addTrustedSigner(signer);
    }

    function test_CanAddMultipleTrustedSigners() public {
        // Add first signer
        importer.addTrustedSigner(signer);
        assertTrue(importer.isTrustedSigner(signer));

        // Add second signer
        importer.addTrustedSigner(signer2);
        assertTrue(importer.isTrustedSigner(signer2));

        // Verify both appear in the list
        address[] memory signers = importer.getAllTrustedSigners();
        assertEq(signers.length, 2);
        assertTrue(_containsAddress(signers, signer));
        assertTrue(_containsAddress(signers, signer2));
    }

    function test_CanRemoveTrustedSigner() public {
        // Add signer first
        importer.addTrustedSigner(signer);
        assertTrue(importer.isTrustedSigner(signer));

        // Remove the signer
        vm.expectEmit();
        emit SignedImporter.TrustedSignerUpdated(signer, false);
        importer.removeTrustedSigner(signer);

        // Confirm that the signer is no longer in the list
        assertFalse(importer.isTrustedSigner(signer));

        // Verify the list is empty
        address[] memory signers = importer.getAllTrustedSigners();
        assertEq(signers.length, 0);
    }

    function test_CannotRemoveNonExistentTrustedSigner() public {
        vm.expectRevert(abi.encodeWithSelector(SignedImporter.SignerDoesNotExist.selector, signer));
        importer.removeTrustedSigner(signer);
    }

    function test_CannotAddTrustedSignerAsNonOwner(address caller) public {
        vm.assume(caller != importer.owner());
        
        vm.startPrank(caller);
        vm.expectRevert(UNAUTHORIZED);
        importer.addTrustedSigner(signer);
        vm.stopPrank();
    }

    function test_CannotRemoveTrustedSignerAsNonOwner(address caller) public {
        vm.assume(caller != importer.owner());

        // Add signer first as owner
        importer.addTrustedSigner(signer);

        // Try to remove as non-owner
        vm.startPrank(caller);
        vm.expectRevert(UNAUTHORIZED);
        importer.removeTrustedSigner(signer);
        vm.stopPrank();
    }

    // ============ AnyPositionManager Management Tests ============

    function test_CanSetAnyPositionManager(address payable _anyPositionManager) public {
        // Ensure that the AnyPositionManager is not the zero address
        vm.assume(_anyPositionManager != address(0));
        
        vm.expectEmit();
        emit SignedImporter.AnyPositionManagerSet(_anyPositionManager);
        importer.setAnyPositionManager(_anyPositionManager);

        assertEq(address(importer.anyPositionManager()), _anyPositionManager);
    }

    function test_CannotSetAnyPositionManagerWithZeroAddress() public {
        vm.expectRevert(SignedImporter.ZeroAddress.selector);
        importer.setAnyPositionManager(payable(address(0)));
    }

    function test_CannotSetAnyPositionManagerAsNonOwner(address caller) public {
        vm.assume(caller != importer.owner());

        vm.startPrank(caller);
        vm.expectRevert(UNAUTHORIZED);
        importer.setAnyPositionManager(payable(address(anyPositionManager)));
        vm.stopPrank();
    }

    // ============ Initialize Tests - Valid Cases ============

    function test_CanInitializeWithValidSignature() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        // Generate valid signature
        uint deadline = block.timestamp + 1 hours;
        bytes memory signature = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        // Should succeed and emit event
        vm.expectEmit();
        emit SignedImporter.TokenImported(TEST_TOKEN, signer);
        
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    // ============ Initialize Tests - Invalid Cases ============

    function test_CannotInitializeWithExpiredDeadline() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        // Generate signature with expired deadline
        uint deadline = block.timestamp - 1;
        bytes memory signature = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        vm.expectRevert(abi.encodeWithSelector(SignedImporter.DeadlineExpired.selector, deadline));
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    function test_CannotInitializeWithInvalidCaller() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        // Generate signature for different creator
        uint deadline = block.timestamp + 1 hours;
        bytes memory signature = _generateSignature(TEST_TOKEN, address(0x999), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(0x999), // Different from msg.sender
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        vm.expectRevert(SignedImporter.InvalidCaller.selector);
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    function test_CannotInitializeWithUntrustedSigner() public {
        // Don't add the signer to trusted list

        // Generate signature
        uint deadline = block.timestamp + 1 hours;
        bytes memory signature = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        vm.expectRevert(abi.encodeWithSelector(SignedImporter.InvalidSigner.selector, signer));
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    function test_CannotInitializeWithReusedSignature() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        // Generate signature
        uint deadline = block.timestamp + 1 hours;
        bytes memory signature = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        // First initialization should succeed
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);

        // Second initialization with same signature should fail
        vm.expectRevert(SignedImporter.SignatureAlreadyUsed.selector);
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    function test_CannotInitializeWithZeroAddressToken() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        // Generate signature for zero address token
        uint deadline = block.timestamp + 1 hours;
        bytes memory signature = _generateSignature(address(0), address(this), deadline, signerPrivateKey);
        
        SignedImporter.SignedMessage memory signedMessage = SignedImporter.SignedMessage({
            token: address(0),
            creator: address(this),
            deadline: deadline,
            signature: signature
        });

        bytes memory verificationData = abi.encode(signedMessage);

        vm.expectRevert(SignedImporter.ZeroAddress.selector);
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, verificationData);
    }

    // ============ Signature Generation and Verification Edge Cases ============

    function test_DifferentSignaturesForDifferentTokens() public {
        // Add trusted signer
        importer.addTrustedSigner(signer);

        uint deadline = block.timestamp + 1 hours;
        
        // Generate signature for first token
        bytes memory signature1 = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        address token2 = address(0x456);
        bytes memory signature2 = _generateSignature(token2, address(this), deadline, signerPrivateKey);

        // Signatures should be different
        assertFalse(keccak256(signature1) == keccak256(signature2));

        // Both should work for their respective tokens
        SignedImporter.SignedMessage memory signedMessage1 = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature1
        });

        SignedImporter.SignedMessage memory signedMessage2 = SignedImporter.SignedMessage({
            token: token2,
            creator: address(this),
            deadline: deadline,
            signature: signature2
        });

        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, abi.encode(signedMessage1));
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, abi.encode(signedMessage2));
    }

    function test_DifferentSignersCanSignSameMessage() public {
        // Add both trusted signers
        importer.addTrustedSigner(signer);
        importer.addTrustedSigner(signer2);

        uint deadline = block.timestamp + 1 hours;
        
        // Generate signatures from different signers for same message data
        bytes memory signature1 = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey);
        bytes memory signature2 = _generateSignature(TEST_TOKEN, address(this), deadline, signerPrivateKey2);

        // Signatures should be different
        assertFalse(keccak256(signature1) == keccak256(signature2));

        // Both should work (but only one can be used due to signature reuse prevention)
        SignedImporter.SignedMessage memory signedMessage1 = SignedImporter.SignedMessage({
            token: TEST_TOKEN,
            creator: address(this),
            deadline: deadline,
            signature: signature1
        });

        // First one should succeed
        importer.initialize(TEST_CREATOR_FEE_ALLOCATION, TEST_INITIAL_MARKET_CAP, abi.encode(signedMessage1));
    }

    // ============ Helper Functions ============

    /**
     * Generates a signature for the SignedImporter verification.
     * 
     * @param _token The token address to sign for
     * @param _creator The creator address to sign for  
     * @param _deadline The deadline for the signature
     * @param _privateKey The private key to use for signing
     *
     * @return signature_ The encoded signature
     */
    function _generateSignature(address _token, address _creator, uint _deadline, uint _privateKey) internal pure returns (bytes memory signature_) {
        bytes32 hash = keccak256(abi.encodePacked(_token, _creator, _deadline));
        bytes32 message = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, message);
        signature_ = abi.encodePacked(r, s, v);
    }

    /**
     * Helper function to check if an address array contains a specific address.
     */
    function _containsAddress(address[] memory _addresses, address _target) internal pure returns (bool) {
        for (uint i = 0; i < _addresses.length; i++) {
            if (_addresses[i] == _target) {
                return true;
            }
        }
        return false;
    }
}
