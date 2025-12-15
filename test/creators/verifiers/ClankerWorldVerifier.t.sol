// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {ClankerWorldVerifier} from '@flaunch/creators/verifiers/ClankerWorldVerifier.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';

import {Test} from 'forge-std/Test.sol';


contract ClankerWorldVerifierTest is Test {

    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);
    address public constant CLANKER_ADDRESS = 0x2A787b2362021cC3eEa3C24C4748a6cD5B687382;

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    ClankerWorldVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));
        
        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new ClankerWorldVerifier();
        verifier.setClankerFactory(CLANKER_ADDRESS, true);
        
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
        address validToken = 0xCBeFeFeaf3914e049db5A5b03aC4964dBf3ebB07;
        
        // Attempt to import the token - should not revert
        // Token Creator: 0xeCFd31add12F4576065b7fD4EcB725250BaC2027
        vm.prank(0xeCFd31add12F4576065b7fD4EcB725250BaC2027);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithInvalidSender() public {
        // The valid token address
        address validToken = 0xCBeFeFeaf3914e049db5A5b03aC4964dBf3ebB07;

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
