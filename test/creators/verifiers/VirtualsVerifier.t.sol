// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {VirtualsVerifier} from '@flaunch/creators/verifiers/VirtualsVerifier.sol';

import {Test} from 'forge-std/Test.sol';

contract VirtualsVerifierTest is Test {
    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    VirtualsVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));

        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new VirtualsVerifier();

        // Register the known Virtuals AgentToken implementations
        verifier.setAgentTokenImplementation(0x9215e9A88c94b9DCAd5B02e32Cd5CaB2A291458B, true);

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
        address validToken = 0xd78d85F92D8562E764dBf91d461ab7348ff1c341;

        // Attempt to import the token - should not revert
        // Token Creator: 0xE220329659D41B2a9F26E83816B424bDAcF62567
        vm.prank(0xE220329659D41B2a9F26E83816B424bDAcF62567);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithInvalidSender() public {
        // The valid token address
        address validToken = 0xd78d85F92D8562E764dBf91d461ab7348ff1c341;

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
