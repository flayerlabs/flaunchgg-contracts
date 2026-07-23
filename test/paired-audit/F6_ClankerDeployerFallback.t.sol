// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from 'forge-std/Test.sol';

import {TokenImporter} from '@flaunch/creators/TokenImporter.sol';
import {ClankerWorldVerifier} from '@flaunch/creators/verifiers/ClankerWorldVerifier.sol';

/**
 * A Clanker v2.0.0 / v3.0.0 style token: it exposes `deployer()` and REVERTS on `admin()`.
 * Clanker v1.x tokens exposed `admin()`; the newer versions dropped it in favour of `deployer()`.
 */
contract MockClankerV2Token {
    address public deployer;

    constructor(
        address _deployer
    ) {
        deployer = _deployer;
    }

    function admin() external pure returns (address) {
        revert('no admin()');
    }
}

/**
 * A minimal Clanker factory that recognises a single registered token, mirroring the shape of
 * `deploymentInfoForToken` that {ClankerWorldVerifier} reads.
 */
contract MockClankerFactory {
    struct DeploymentInfo {
        address token;
        uint positionId;
        address locker;
    }

    address public registeredToken;

    function setRegisteredToken(
        address _token
    ) external {
        registeredToken = _token;
    }

    function deploymentInfoForToken(
        address _token
    ) external view returns (DeploymentInfo memory info_) {
        // Only the registered token is recognised; everything else returns a zero token
        if (_token == registeredToken) {
            info_.token = _token;
        }
    }
}

/**
 * Regression coverage for audit finding F-6.
 *
 * `ClankerWorldVerifier.isValid` previously called `admin()` unconditionally, which reverts on
 * Clanker v2/v3 tokens (they expose `deployer()`), DoSing both the import and the TokenImporter
 * auto-verify loop. The verifier must now probe `admin()` then fall back to `deployer()` and
 * return `false` (never revert) when neither matches the sender.
 */
contract F6ClankerDeployerFallbackTest is Test {
    ClankerWorldVerifier internal verifier;
    MockClankerFactory internal factory;
    MockClankerV2Token internal token;

    address internal deployer;
    address internal notDeployer;

    function setUp() public {
        deployer = makeAddr('clankerDeployer');
        notDeployer = makeAddr('notDeployer');

        verifier = new ClankerWorldVerifier();
        factory = new MockClankerFactory();
        token = new MockClankerV2Token(deployer);

        factory.setRegisteredToken(address(token));
        verifier.setClankerFactory(address(factory), true);
    }

    /**
     * Confirm our mock genuinely models a Clanker v2/v3 token: `admin()` reverts. Before the fix
     * this revert would have bubbled out of `isValid`.
     */
    function test_F6_AdminSelectorReverts() public {
        (bool success,) = address(token).staticcall(abi.encodeWithSignature('admin()'));
        assertFalse(success, 'mock unexpectedly returned from admin()');
    }

    /**
     * The verifier falls back to `deployer()` and validates the true deployer.
     */
    function test_F6_DeployerFallbackReturnsTrue() public view {
        assertTrue(verifier.isValid(address(token), deployer), 'deployer should be valid');
    }

    /**
     * A non-deployer is rejected with `false` (not a revert), even though `admin()` reverts.
     */
    function test_F6_NonDeployerReturnsFalseNotRevert() public view {
        assertFalse(verifier.isValid(address(token), notDeployer), 'non-deployer should be invalid');
    }

    /**
     * The {TokenImporter} auto-verify loop (`verifyMemecoin`) must not revert on a token whose
     * `admin()` reverts. It resolves the verifier for the deployer and returns the zero address
     * for a non-deployer, all without reverting.
     */
    function test_F6_TokenImporterAutoVerifyDoesNotRevert() public {
        // The TokenImporter constructor only stores the AnyPositionManager address (no calls),
        // so a non-zero placeholder is sufficient for exercising the verify loop.
        TokenImporter importer = new TokenImporter(payable(address(0xA11CE)));
        importer.addVerifier(address(verifier));

        // As the deployer, the loop resolves our verifier without reverting
        vm.prank(deployer);
        assertEq(importer.verifyMemecoin(address(token)), address(verifier), 'verifier not resolved for deployer');

        // As a non-deployer, the loop returns the zero address (still no revert)
        vm.prank(notDeployer);
        assertEq(importer.verifyMemecoin(address(token)), address(0), 'unexpected verifier for non-deployer');
    }
}
