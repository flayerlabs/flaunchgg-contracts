// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {DopplerVerifier} from '@flaunch/creators/verifiers/DopplerVerifier.sol';

import {Test} from 'forge-std/Test.sol';

contract DopplerVerifierTest is Test {
    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);
    address public constant DOPPLER_AIRLOCK_ADDRESS = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    DopplerVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));

        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new DopplerVerifier(DOPPLER_AIRLOCK_ADDRESS);

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
        address validToken = 0x4afc4e31bAA3a7f8DbF6272c5b433EcE29F44834;

        // Attempt to import the token - should not revert
        // Token Creator: 0x0792cc3Ec1A2Ca556dE1DF1112d358bA7F67db53
        vm.prank(0x0792cc3Ec1A2Ca556dE1DF1112d358bA7F67db53);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithInvalidSender() public {
        // The valid token address
        address validToken = 0x4afc4e31bAA3a7f8DbF6272c5b433EcE29F44834;

        // Attempt to import the token - should revert
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
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
