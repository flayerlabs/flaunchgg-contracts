// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ImportVerifierMock} from '../mocks/ImportVerifierMock.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

contract TokenImporterTest is FlaunchTest {
    TokenImporter public importer;

    ImportVerifierMock public mockVerifier;

    address public constant TEST_TOKEN = address(0x123);
    uint24 public constant TEST_CREATOR_FEE_ALLOCATION = 80_00;

    function setUp() public {
        _deployPlatform();

        // Deploy the importer
        importer = new TokenImporter(payable(address(anyPositionManager)));

        // Approve the importer against the AnyPositionManager
        anyPositionManager.approveCreator(address(importer), true);

        // Deploy mock verifiers
        mockVerifier = new ImportVerifierMock();
    }

    function test_cannotDeployWithZeroAddress() public {
        // Test zero address
        vm.expectRevert(TokenImporter.ZeroAddress.selector);
        new TokenImporter(payable(address(0)));
    }

    function test_canAddVerifier() public {
        // Test adding verifier
        importer.addVerifier(address(mockVerifier));
        assertTrue(_isVerifier(address(mockVerifier)));

        // Test adding duplicate verifier
        vm.expectRevert(TokenImporter.VerifierAlreadyAdded.selector);
        importer.addVerifier(address(mockVerifier));

        // Test adding zero address
        vm.expectRevert(TokenImporter.ZeroAddress.selector);
        importer.addVerifier(address(0));
    }

    function test_canRemoveVerifier() public {
        // Add verifier first
        importer.addVerifier(address(mockVerifier));

        // Test removing verifier
        importer.removeVerifier(address(mockVerifier));
        assertFalse(_isVerifier(address(mockVerifier)));

        // Test removing non-existent verifier
        vm.expectRevert(TokenImporter.VerifierNotAdded.selector);
        importer.removeVerifier(address(mockVerifier));

        // Test that we can add the verifier again
        importer.addVerifier(address(mockVerifier));
        assertTrue(_isVerifier(address(mockVerifier)));
    }

    function test_CanVerifyMemecoin() public {
        // Add valid verifier
        importer.addVerifier(address(mockVerifier));

        // Test valid memecoin
        mockVerifier.setIsValid(true);
        address chosenVerifier = importer.verifyMemecoin(TEST_TOKEN);
        assertEq(chosenVerifier, address(mockVerifier));

        // Test invalid memecoin
        mockVerifier.setIsValid(false);
        chosenVerifier = importer.verifyMemecoin(TEST_TOKEN);
        assertEq(chosenVerifier, address(0));
    }

    function test_CanInitialize() public {
        mockVerifier.setIsValid(true);
        importer.addVerifier(address(mockVerifier));

        vm.expectEmit();
        emit TokenImporter.TokenImported(TEST_TOKEN, address(mockVerifier));

        importer.initialize(TEST_TOKEN, TEST_CREATOR_FEE_ALLOCATION, 5000e6);
    }

    function test_CannotInitializeWithInvalidMemecoin() public {
        // Set the verifier to return false (invalid memecoin)
        mockVerifier.setIsValid(false);
        importer.addVerifier(address(mockVerifier));

        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(TEST_TOKEN, TEST_CREATOR_FEE_ALLOCATION, 5000e6);
    }

    function test_CanInitializeWithVerifier() public {
        mockVerifier.setIsValid(true);
        importer.addVerifier(address(mockVerifier));

        vm.expectEmit();
        emit TokenImporter.TokenImported(TEST_TOKEN, address(mockVerifier));

        importer.initialize(TEST_TOKEN, TEST_CREATOR_FEE_ALLOCATION, 5000e6, address(mockVerifier));
    }

    function test_CannotInitializeWithVerifierNotAdded() public {
        mockVerifier.setIsValid(true);

        vm.expectRevert(TokenImporter.VerifierNotAdded.selector);
        importer.initialize(TEST_TOKEN, TEST_CREATOR_FEE_ALLOCATION, 5000e6, address(mockVerifier));
    }

    function test_CannotInitializeWithVerifierInvalidMemecoin() public {
        mockVerifier.setIsValid(false);
        importer.addVerifier(address(mockVerifier));

        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(TEST_TOKEN, TEST_CREATOR_FEE_ALLOCATION, 5000e6, address(mockVerifier));
    }

    function test_CanSetAnyPositionManager(
        address payable _anyPositionManager
    ) public {
        // Ensure that the AnyPositionManager is not the zero address
        vm.assume(_anyPositionManager != address(0));

        // Set the AnyPositionManager contract
        importer.setAnyPositionManager(_anyPositionManager);

        // Confirm that the AnyPositionManager contract is set
        assertEq(address(importer.anyPositionManager()), _anyPositionManager);
    }

    function test_CannotSetAnyPositionManagerWithNonOwner(
        address _caller,
        address payable _anyPositionManager
    ) public {
        // Ensure that the AnyPositionManager is not the zero address
        vm.assume(_anyPositionManager != address(0));

        // Ensure that the caller is not the owner
        vm.assume(_caller != importer.owner());
        vm.startPrank(_caller);

        // We should be reverted when trying to set the AnyPositionManager contract with anyone other than
        // the approved owner address.
        vm.expectRevert(UNAUTHORIZED);
        importer.setAnyPositionManager(_anyPositionManager);

        vm.stopPrank();
    }

    function test_CannotSetAnyPositionManagerWithZeroAddress() public {
        // We should be reverted when trying to set the AnyPositionManager contract with the zero address.
        vm.expectRevert(TokenImporter.ZeroAddress.selector);
        importer.setAnyPositionManager(payable(address(0)));
    }

    function _isVerifier(
        address _verifier
    ) internal view returns (bool isVerifier_) {
        address[] memory verifiers = importer.getAllVerifiers();
        for (uint i = 0; i < verifiers.length; i++) {
            if (verifiers[i] == _verifier) {
                isVerifier_ = true;
            }
        }
    }
}
