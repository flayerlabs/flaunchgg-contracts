// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {ZoraVerifier} from '@flaunch/creators/verifiers/ZoraVerifier.sol';

import {Test} from 'forge-std/Test.sol';

contract ZoraVerifierTest is Test {
    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    ZoraVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));

        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new ZoraVerifier();

        // Register the known Zora coin implementations
        verifier.setZoraCoinImplementation(0xeBCc4B0Cf2cFD448616d3cb42C5825528b60317D, true);
        verifier.setZoraCoinImplementation(0xbECAe78D441FBa11017bB7A8798D018b0977F76d, true);

        // Add the verifier to the importer
        vm.startPrank(anyPositionManager.owner());
        anyPositionManager.approveCreator(address(importer), true);

        // Ensure we have the expected initialPrice calculator
        anyPositionManager.setInitialPrice(0xf318E170D10A1F0d9b57211e908a7f081123E7f6);
        vm.stopPrank();

        // Add the verifier to the importer
        importer.addVerifier(address(verifier));
    }

    function test_CanImportValidToken() public {
        // The valid token address
        address validToken = 0x3BdA8AdA097F2b21220D9CC5400B2E577947730F;

        // Attempt to import the token - should not revert.
        // The verifier now binds to the canonical payoutRecipient (the authoritative creator) rather
        // than any co-owner of the Zora coin.
        // payoutRecipient: 0x5E484ED0a94879d938A1c567cF5727A6Ba33D4C0
        vm.prank(0x5E484ED0a94879d938A1c567cF5727A6Ba33D4C0);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithInvalidSender() public {
        // The valid token address
        address validToken = 0x3BdA8AdA097F2b21220D9CC5400B2E577947730F;

        // A co-owner that is NOT the payoutRecipient must no longer be able to import. Under the
        // previous "any isOwner" rule this address would have passed; binding to the authoritative
        // payoutRecipient (F-7) now rejects it. 0xaCB6... is one of the coin's owners() but not the
        // payoutRecipient.
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        vm.prank(0xaCB6122046Dea47Ae42FEadd348C0430913B8034);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportInvalidToken() public {
        // An invalid token address
        address invalidToken = address(0x123);

        // Attempt to import the token - should revert
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(invalidToken, 80_00, 5000e6);
    }
}
