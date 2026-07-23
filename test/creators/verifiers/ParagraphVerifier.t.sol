// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {ParagraphVerifier} from '@flaunch/creators/verifiers/ParagraphVerifier.sol';

import {Test} from 'forge-std/Test.sol';

interface IUniswapV4MulticurveInitializer {
    struct BeneficiaryData {
        address beneficiary;
        uint96 shares;
    }

    function getBeneficiaries(
        address asset
    ) external view returns (BeneficiaryData[] memory);
}

contract ParagraphVerifierTest is Test {
    address payable public constant ANY_POSITION_MANAGER_ADDRESS = payable(0x2aD43d0618b1d8a0CC75CF716Cf0bf64070725dC);
    address public constant UNISWAP_V4_MULTICURVE_INITIALIZER_ADDRESS = 0x65dE470Da664A5be139A5D812bE5FDa0d76CC951;

    AnyPositionManager public anyPositionManager;
    TokenImporter public importer;
    ParagraphVerifier public verifier;

    function setUp() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));

        // Register our AnyPositionManager
        anyPositionManager = AnyPositionManager(ANY_POSITION_MANAGER_ADDRESS);

        // Deploy the importer
        importer = new TokenImporter(ANY_POSITION_MANAGER_ADDRESS);

        // Register the verifier
        verifier = new ParagraphVerifier(UNISWAP_V4_MULTICURVE_INITIALIZER_ADDRESS);

        // Approve the importer as a creator in AnyPositionManager
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
        address validToken = 0x494Eb6A16A3d7B6d1dc5A4a64fCf5ED3B704d067;

        // Get the beneficiary address for this token from the contract
        // We need to query the actual beneficiary from the paragraph contract
        IUniswapV4MulticurveInitializer paragraph = IUniswapV4MulticurveInitializer(UNISWAP_V4_MULTICURVE_INITIALIZER_ADDRESS);

        IUniswapV4MulticurveInitializer.BeneficiaryData[] memory beneficiaries = paragraph.getBeneficiaries(validToken);

        require(beneficiaries.length > 0, 'No beneficiaries found');

        // Use the first beneficiary as the sender
        address tokenBeneficiary = beneficiaries[0].beneficiary;

        // Attempt to import the token - should not revert
        vm.prank(tokenBeneficiary);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithInvalidSender() public {
        // The valid token address
        address validToken = 0x494Eb6A16A3d7B6d1dc5A4a64fCf5ED3B704d067;

        // Attempt to import the token with a non-beneficiary address - should revert
        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        importer.initialize(validToken, 80_00, 5000e6);
    }

    function test_CannotImportValidTokenWithNonPrimaryBeneficiary() public {
        // The valid token address
        address validToken = 0x494Eb6A16A3d7B6d1dc5A4a64fCf5ED3B704d067;

        IUniswapV4MulticurveInitializer paragraph = IUniswapV4MulticurveInitializer(UNISWAP_V4_MULTICURVE_INITIALIZER_ADDRESS);
        IUniswapV4MulticurveInitializer.BeneficiaryData[] memory beneficiaries = paragraph.getBeneficiaries(validToken);
        require(beneficiaries.length > 1, 'Need multiple beneficiaries for this test');

        // Resolve the primary (largest-share) beneficiary, then pick a different, lower/equal-share
        // beneficiary. Under the previous "any beneficiary" rule this address would have imported;
        // binding to the primary beneficiary (F-7) now rejects it.
        uint primaryIndex;
        for (uint i = 1; i < beneficiaries.length; ++i) {
            if (beneficiaries[i].shares > beneficiaries[primaryIndex].shares) {
                primaryIndex = i;
            }
        }

        address nonPrimary;
        for (uint i = 0; i < beneficiaries.length; ++i) {
            if (i != primaryIndex && beneficiaries[i].beneficiary != beneficiaries[primaryIndex].beneficiary) {
                nonPrimary = beneficiaries[i].beneficiary;
                break;
            }
        }
        require(nonPrimary != address(0), 'No distinct non-primary beneficiary');

        vm.expectRevert(TokenImporter.InvalidMemecoin.selector);
        vm.prank(nonPrimary);
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
