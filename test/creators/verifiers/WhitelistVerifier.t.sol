// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {WhitelistVerifier} from '@flaunch/creators/verifiers/WhitelistVerifier.sol';

import {Test} from 'forge-std/Test.sol';

contract WhitelistVerifierTest is Test {
    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    WhitelistVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));

        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new WhitelistVerifier();

        // Add the verifier to the importer
        vm.startPrank(anyPositionManager.owner());
        anyPositionManager.approveCreator(address(importer), true);

        // Ensure we have the expected initialPrice calculator
        anyPositionManager.setInitialPrice(0xf318E170D10A1F0d9b57211e908a7f081123E7f6);
        vm.stopPrank();

        // Add the verifier to the importer
        importer.addVerifier(address(verifier));
    }

    function test_CanImportValidToken(
        address _token,
        address _sender
    ) public {
        // Ensure that our addresses are not zero address
        vm.assume(_token != address(0));
        vm.assume(_sender != address(0));

        // Ensure the fuzzed token cannot collide with the native token, which would
        // produce a PoolKey with currency0 == currency1
        vm.assume(_token != anyPositionManager.nativeToken());

        // Approve the sender
        verifier.setWhitelist(_sender, _token);

        // Confirm the sender is whitelisted
        assertEq(verifier.whitelist(_token), _sender);

        // Attempt to import the token - should not revert
        vm.prank(_sender);
        importer.initialize(_token, 80_00, 5000e6);
    }

    function test_CannotImportInvalidToken_UnknownMemecoin(
        address _token
    ) public {
        // Ensure that the token is not a zero address
        vm.assume(_token != address(0));

        // Attempt to import the token - should revert
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(_token, 80_00, 5000e6);
    }

    function test_CannotImportInvalidToken_ZeroAddress() public {
        // Attempt to import the token - should revert
        vm.expectRevert(TokenImporter.ZeroAddress.selector);
        importer.initialize(address(0), 80_00, 5000e6);
    }

    function test_CannotImportInvalidToken_UnknownSender(
        address _token,
        address _sender
    ) public {
        // Ensure that the token is not a zero address
        vm.assume(_token != address(0));

        // Ensure that the sender is not a zero address or the test contract
        vm.assume(_sender != address(0));
        vm.assume(_sender != address(this));

        // Approve this address to be whitelisted
        verifier.setWhitelist(address(this), _token);

        // Make the call as another sender
        vm.startPrank(_sender);

        // Attempt to import the token - should revert
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(_token, 80_00, 5000e6);

        vm.stopPrank();
    }
}
