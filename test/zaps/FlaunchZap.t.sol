// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {TrustedSignerFeeCalculator as TrustedSignerFeeCalculatorContract} from '@flaunch/fees/TrustedSignerFeeCalculator.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {FlaunchZap} from '@flaunch/zaps/FlaunchZap.sol';

import {IFlaunchZap} from '@flaunch-interfaces/IFlaunchZap.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';

import {CompatibleManagerMock, IncompatibleManagerMock} from 'test/mocks/ManagerMock.sol';
import {FlaunchTest} from '../FlaunchTest.sol';

/**
 * Coverage for the {FlaunchZap} treasury-manager-at-flaunch flow.
 *
 * When `TreasuryManagerParams.manager` is supplied, the zap flaunches with itself as the temporary
 * creator so it receives the Flaunch ERC721, then escrows the token into the manager: an approved
 * implementation is deployed through the factory and deposited into; a factory-deployed instance is
 * deposited into directly; an unknown address gets a best-effort deposit with a direct transfer
 * fallback. Any premine is swept to the original creator.
 */
contract FlaunchZapTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    /// An approved manager implementation registered against the factory mock
    CompatibleManagerMock internal managerImplementation;

    function setUp() public {
        _deployPlatform();

        // Register an approved manager implementation on the factory (constructor args are
        // irrelevant for an implementation that will be cloned + initialized)
        managerImplementation = new CompatibleManagerMock(address(this), address(0));
        treasuryManagerFactory.approveManager(address(managerImplementation));

        vm.deal(address(this), 1000e27);
    }

    function _params(
        address _creator,
        uint _premineAmount
    ) internal pure returns (IPositionManager.FlaunchParams memory) {
        return IPositionManager.FlaunchParams({
            name: 'Manager Zap Token',
            symbol: 'MZAP',
            tokenUri: 'https://flaunch.gg/',
            premineAmount: _premineAmount,
            creator: _creator,
            creatorFeeAllocation: 50_00,
            flaunchAt: 0,
            initialPriceParams: abi.encode(''),
            feeCalculatorParams: abi.encode(1_000)
        });
    }

    function _managerParams(
        address _manager,
        address _permissions
    ) internal pure returns (IFlaunchZap.TreasuryManagerParams memory) {
        return IFlaunchZap.TreasuryManagerParams({
            manager: _manager,
            permissions: _permissions,
            initializeData: abi.encode('init'),
            depositData: abi.encode('deposit')
        });
    }

    /* -------------------------------------------------------------------------- */
    /*   1 - approved implementation: deploy + deposit (+ optional permissions)    */
    /* -------------------------------------------------------------------------- */

    function test_CanFlaunchWithApprovedManagerImplementation() public {
        address creator = makeAddr('creator');

        (address memecoin,, address deployedManager) = flaunchZap.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(address(managerImplementation), address(0)),
            _trustedFeeSigner: address(0)
        });

        // A fresh instance was cloned from the implementation
        assertTrue(deployedManager != address(0), 'no manager deployed');
        assertTrue(deployedManager != address(managerImplementation), 'implementation was used directly');
        assertEq(
            treasuryManagerFactory.managerImplementation(deployedManager),
            address(managerImplementation),
            'clone not registered against the implementation'
        );

        // The Flaunch ERC721 was deposited into the deployed manager on behalf of the creator
        uint tokenId = flaunch.tokenId(memecoin);
        assertEq(flaunch.ownerOf(tokenId), deployedManager, 'NFT not deposited into the manager');

        CompatibleManagerMock manager = CompatibleManagerMock(deployedManager);
        assertEq(manager.lastCreator(), creator, 'deposit not recorded against the creator');
        assertEq(manager.lastDepositData(), abi.encode('deposit'), 'deposit data not forwarded');

        // With no permissions, the creator owns the manager from deployment
        assertEq(manager.managerOwner(), creator, 'creator does not own the manager');
    }

    function test_CanFlaunchWithApprovedManagerImplementation_WithPermissions() public {
        address creator = makeAddr('creator');
        address permissions = makeAddr('permissions');

        (address memecoin,, address deployedManager) = flaunchZap.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(address(managerImplementation), permissions),
            _trustedFeeSigner: address(0)
        });

        // The zap owned the manager while it set the permissions, then handed it to the creator
        CompatibleManagerMock manager = CompatibleManagerMock(deployedManager);
        assertEq(address(manager.permissions()), permissions, 'permissions not applied');
        assertEq(manager.managerOwner(), creator, 'ownership not handed to the creator');
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), deployedManager, 'NFT not deposited into the manager');
    }

    /* -------------------------------------------------------------------------- */
    /*   2 - previously deployed factory instance: deposit directly                */
    /* -------------------------------------------------------------------------- */

    function test_CanFlaunchWithPreDeployedManagerInstance() public {
        address creator = makeAddr('creator');

        // Deploy an instance through the factory up-front; the zap must recognise it and deposit
        // into it rather than cloning it
        address payable instance = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: address(managerImplementation),
            _owner: address(this),
            _data: ''
        });

        (address memecoin,, address deployedManager) = flaunchZap.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(instance, address(0)),
            _trustedFeeSigner: address(0)
        });

        assertEq(deployedManager, instance, 'existing instance should be used directly');
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), instance, 'NFT not deposited into the instance');
        assertEq(CompatibleManagerMock(instance).lastCreator(), creator, 'deposit not recorded against the creator');
    }

    /* -------------------------------------------------------------------------- */
    /*   3 - unknown manager: best-effort deposit / direct transfer fallback       */
    /* -------------------------------------------------------------------------- */

    function test_CanFlaunchWithUnknownCompatibleManager() public {
        address creator = makeAddr('creator');

        // A compatible manager that the factory has never seen: the zap's best-effort deposit
        // succeeds and the manager pulls the NFT itself
        CompatibleManagerMock unknownManager = new CompatibleManagerMock(address(this), address(0));

        (address memecoin,, address deployedManager) = flaunchZap.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(address(unknownManager), address(0)),
            _trustedFeeSigner: address(0)
        });

        assertEq(deployedManager, address(unknownManager), 'unknown manager should be used directly');
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), address(unknownManager), 'NFT not deposited');
        assertEq(unknownManager.lastCreator(), creator, 'deposit not recorded against the creator');
    }

    function test_CanFlaunchWithUnknownIncompatibleManager() public {
        address creator = makeAddr('creator');

        // A manager without a deposit function: its fallback swallows the deposit call without
        // pulling the NFT, so the zap must transfer the token to it directly
        IncompatibleManagerMock incompatibleManager = new IncompatibleManagerMock(address(this));

        (address memecoin,, address deployedManager) = flaunchZap.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(address(incompatibleManager), address(0)),
            _trustedFeeSigner: address(0)
        });

        assertEq(deployedManager, address(incompatibleManager), 'incompatible manager should be used directly');
        assertEq(
            flaunch.ownerOf(flaunch.tokenId(memecoin)), address(incompatibleManager), 'NFT not transferred directly'
        );
    }

    /* -------------------------------------------------------------------------- */
    /*   4 - composition with the trusted-signer path                              */
    /* -------------------------------------------------------------------------- */

    function test_ManagerWithTrustedSigner_NftToManager_PremineToCreator() public {
        address creator = makeAddr('creator');
        uint premineAmount = 0.001 ether;
        (address signer,) = makeAddrAndKey('signer');

        // The trusted-signer flow requires the {TrustedSignerFeeCalculator} to be active
        TrustedSignerFeeCalculatorContract feeCalculator = new TrustedSignerFeeCalculatorContract(address(flETH));
        feeCalculator.grantRole(ProtocolRoles.POSITION_MANAGER, address(positionManager));
        positionManager.setFeeCalculator(feeCalculator);

        IPositionManager.FlaunchParams memory params = _params(creator, premineAmount);
        params.creatorFeeAllocation = 0;
        params.feeCalculatorParams = abi.encode(false, uint(0), uint(0));

        (address memecoin,, address deployedManager) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: params,
            _treasuryManagerParams: _managerParams(address(managerImplementation), address(0)),
            _trustedFeeSigner: signer
        });

        // The trusted signer was registered against the created pool
        PoolKey memory poolKey = positionManager.poolKey(memecoin);
        (address poolSigner, bool enabled) = feeCalculator.trustedPoolKeySigner(poolKey.toId());
        assertEq(poolSigner, signer, 'trusted signer not registered');
        assertTrue(enabled, 'trusted signer not enabled');

        // The NFT went to the manager and the premine to the original creator; the zap holds neither
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), deployedManager, 'NFT not deposited into the manager');
        assertEq(CompatibleManagerMock(deployedManager).lastCreator(), creator, 'deposit not recorded against creator');
        assertEq(IERC20(memecoin).balanceOf(creator), premineAmount, 'creator did not receive the premine');
        assertEq(IERC20(memecoin).balanceOf(address(flaunchZap)), 0, 'zap stranded the premine');
        assertEq(address(flaunchZap).balance, 0, 'zap stranded ETH');
    }

    /* -------------------------------------------------------------------------- */
    /*   5 - zap without a factory bound: unknown-manager path still works         */
    /* -------------------------------------------------------------------------- */

    function test_FactoryZeroAddress_FallsBackToUnknownManagerPath() public {
        address creator = makeAddr('creator');

        FlaunchZap zapWithoutFactory =
            new FlaunchZap(positionManager, flaunch, ITreasuryManagerFactory(address(0)));

        // Even an APPROVED implementation routes through the unknown-manager path (no factory to
        // consult), so the deposit is made against the implementation address itself
        CompatibleManagerMock unknownManager = new CompatibleManagerMock(address(this), address(0));

        (address memecoin,, address deployedManager) = zapWithoutFactory.flaunch({
            _flaunchParams: _params(creator, 0),
            _treasuryManagerParams: _managerParams(address(unknownManager), address(0)),
            _trustedFeeSigner: address(0)
        });

        assertEq(deployedManager, address(unknownManager), 'manager should be used directly without a factory');
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), address(unknownManager), 'NFT not deposited');

        // The explicit deploy helper cannot work without a factory
        vm.expectRevert(IFlaunchZap.TreasuryManagerFactoryNotSet.selector);
        zapWithoutFactory.deployAndInitializeManager(address(managerImplementation), creator, '', address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*   6 - guards                                                                */
    /* -------------------------------------------------------------------------- */

    function test_ManagerOverload_RevertsCreatorCannotBeZero() public {
        vm.expectRevert(IFlaunchZap.CreatorCannotBeZero.selector);
        flaunchZap.flaunch({
            _flaunchParams: _params(address(0), 0),
            _treasuryManagerParams: _managerParams(address(managerImplementation), address(0)),
            _trustedFeeSigner: address(0)
        });
    }

    /* -------------------------------------------------------------------------- */
    /*   7 - empty manager params behave exactly like the plain overload           */
    /* -------------------------------------------------------------------------- */

    function test_EmptyManagerParams_MatchesExistingOverload() public {
        address creator = makeAddr('creator');
        uint premineAmount = 0.001 ether;

        IFlaunchZap.TreasuryManagerParams memory noManager;

        (address memecoin,, address deployedManager) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: _params(creator, premineAmount),
            _treasuryManagerParams: noManager,
            _trustedFeeSigner: address(0)
        });

        // No manager involved: the NFT and premine are delivered straight to the creator
        assertEq(deployedManager, address(0), 'no manager should be deployed');
        assertEq(flaunch.ownerOf(flaunch.tokenId(memecoin)), creator, 'creator should hold the NFT');
        assertEq(IERC20(memecoin).balanceOf(creator), premineAmount, 'creator should receive the premine');
        assertEq(IERC20(memecoin).balanceOf(address(flaunchZap)), 0, 'zap must not strand memecoin');
        assertEq(address(flaunchZap).balance, 0, 'zap must refund all leftover ETH');
    }

    /* -------------------------------------------------------------------------- */
    /*   8 - deployAndInitializeManager helper                                     */
    /* -------------------------------------------------------------------------- */

    function test_CanDeployAndInitializeManager() public {
        address owner = makeAddr('managerOwner');
        address permissions = makeAddr('permissions');

        address payable manager =
            flaunchZap.deployAndInitializeManager(address(managerImplementation), owner, abi.encode('init'), permissions);

        // The zap owned the manager while setting permissions, then handed ownership over
        CompatibleManagerMock deployed = CompatibleManagerMock(manager);
        assertEq(address(deployed.permissions()), permissions, 'permissions not applied');
        assertEq(deployed.managerOwner(), owner, 'ownership not handed over');
        assertEq(
            treasuryManagerFactory.managerImplementation(manager),
            address(managerImplementation),
            'manager not registered against the implementation'
        );
    }
}
