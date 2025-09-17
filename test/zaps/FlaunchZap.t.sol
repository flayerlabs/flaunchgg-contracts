// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {FlaunchZap} from '@flaunch/zaps/FlaunchZap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {TreasuryManagerMock} from 'test/mocks/TreasuryManagerMock.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';
import {TrustedSignerFeeCalculator} from '@flaunch/fees/TrustedSignerFeeCalculator.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {ClosedPermissions} from '@flaunch/treasury/permissions/Closed.sol';
import {WhitelistedPermissions} from '@flaunch/treasury/permissions/Whitelisted.sol';
import {IManagerPermissions} from '@flaunch-interfaces/IManagerPermissions.sol';
import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract FlaunchZapTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    IManagerPermissions public closedPermissions;
    IManagerPermissions public whitelistedPermissions;

    // Structs to group related parameters and avoid stack too deep
    struct FuzzParams {
        uint initialTokenFairLaunch;
        uint premineAmount;
        address creator;
        uint initialPrice;
        uint airdropAmount;
        address manager;
        bytes32 whitelistMerkleRoot;
        uint whitelistMaxTokens;
        bool isClosedPermissions;
    }

    struct FlaunchResult {
        address memecoin;
        uint ethSpent;
        address deployedManager;
    }

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // {PoolManager} must have some initial flETH balance to serve `take()` requests in our hook
        deal(address(flETH), address(poolManager), 1000e27 ether);

        closedPermissions = new ClosedPermissions();
        whitelistedPermissions = new WhitelistedPermissions(treasuryManagerFactory);
    }

    /**
     * This test fuzzes as many relevant factors as possible and then validates based on the
     * expected user journey. The only variables fuzzed will be those that affect zap
     * functionality. The other variables are tested in other suites.
     *
     * @param _initialTokenFairLaunch The amount of tokens available during the fair launch period
     * @param _premineAmount The amount of tokens to premine from the fair launch
     * @param _creator The recipient of the ERC721 token
     * @param _initialPrice The initial price of the token
     *
     * @param _airdropAmount The amount of tokens to airdrop from the fair launch
     *
     * @param _manager An optional manager for the ERC721 token
     *
     * @param _whitelistMerkleRoot An optional merkle root for the whitelist
     * @param _whitelistMaxTokens The maximum number of tokens in the whitelist
     */
    function test_CanFlaunch(
        uint _initialTokenFairLaunch,
        uint _premineAmount,
        address _creator,
        uint _initialPrice,
        uint _airdropAmount,
        address _manager,
        bytes32 _whitelistMerkleRoot,
        uint _whitelistMaxTokens,
        bool isClosedPermissions
    ) public {
        FuzzParams memory params = FuzzParams({
            initialTokenFairLaunch: _initialTokenFairLaunch,
            premineAmount: _premineAmount,
            creator: _creator,
            initialPrice: _initialPrice,
            airdropAmount: _airdropAmount,
            manager: _manager,
            whitelistMerkleRoot: _whitelistMerkleRoot,
            whitelistMaxTokens: _whitelistMaxTokens,
            isClosedPermissions: isClosedPermissions
        });

        // Validate parameters
        _validateFuzzParams(params);

        // Setup test environment
        _setupTestEnvironment();

        // Execute flaunch
        FlaunchResult memory result = _executeFlaunch(params);

        // Validate results
        _validateWhitelist(result.memecoin, params);
        _validateAirdrop(result.memecoin, params);
        _validateTreasuryManager(result.deployedManager, params);
        _validateRefundedETH(result.ethSpent);
    }

    function _validateFuzzParams(FuzzParams memory params) internal view {
        // Ensure that the creator is not a zero address, as this will revert
        vm.assume(params.creator != address(0));

        // Ensure that our initial token supply is valid (InvalidInitialSupply)
        vm.assume(params.initialTokenFairLaunch <= flaunch.MAX_FAIR_LAUNCH_TOKENS());

        // Ensure that our premine does not exceed the fair launch (PremineExceedsInitialAmount)
        vm.assume(params.premineAmount <= params.initialTokenFairLaunch);

        // Ensure that if we are airdropping, that the amount is not greater than the premine amount
        vm.assume(params.airdropAmount <= params.premineAmount);
    }

    function _setupTestEnvironment() internal {
        // Provide our user with enough FLETH to make the premine swap
        deal(address(this), 2000e27);
        flETH.deposit{value: 1000e27}();
        flETH.approve(address(flaunchZap), 1000e27);
    }

    function _executeFlaunch(FuzzParams memory params) internal returns (FlaunchResult memory) {
        // Flaunch time baby!
        (address memecoin_, uint ethSpent_, address deployedManager_) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: PositionManager.FlaunchParams({
                name: 'FlaunchZap',
                symbol: 'ZAP',
                tokenUri: 'ipfs://123',
                initialTokenFairLaunch: params.initialTokenFairLaunch,
                fairLaunchDuration: 0,
                premineAmount: params.premineAmount,
                creator: params.creator,
                creatorFeeAllocation: 80_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(params.initialPrice),
                feeCalculatorParams: abi.encode('')
            }),
            _trustedFeeSigner: address(0),
            _premineSwapHookData: bytes(''),
            _whitelistParams: FlaunchZap.WhitelistParams({
                merkleRoot: params.whitelistMerkleRoot,
                merkleIPFSHash: 'ipfs://123',
                maxTokens: params.whitelistMaxTokens
            }),
            _airdropParams: FlaunchZap.AirdropParams({
                airdropIndex: 0,
                airdropAmount: params.airdropAmount,
                airdropEndTime: block.timestamp + 30 days,
                merkleRoot: bytes32('testing'),
                merkleIPFSHash: 'ipfs://'
            }),
            _treasuryManagerParams: FlaunchZap.TreasuryManagerParams({
                manager: params.manager,
                permissions: params.isClosedPermissions ? address(closedPermissions) : address(whitelistedPermissions),
                initializeData: abi.encode(''),
                depositData: abi.encode('')
            })
        });

        return FlaunchResult({
            memecoin: memecoin_,
            ethSpent: ethSpent_,
            deployedManager: deployedManager_
        });
    }

    function _validateWhitelist(address memecoin, FuzzParams memory params) internal view {
        // Check our whitelist
        (bytes32 root, string memory ipfs, uint maxTokens, bool active, bool exists) = whitelistFairLaunch.whitelistMerkles(
            positionManager.poolKey(memecoin).toId()
        );

        if (params.whitelistMerkleRoot != '' && params.initialTokenFairLaunch != 0) {
            assertEq(root, params.whitelistMerkleRoot);
            assertEq(ipfs, 'ipfs://123');
            assertEq(maxTokens, params.whitelistMaxTokens);
            assertEq(active, true);
            assertEq(exists, true);
        } else {
            assertEq(root, '');
            assertEq(ipfs, '');
            assertEq(maxTokens, 0);
            assertEq(active, false);
            assertEq(exists, false);
        }
    }

    function _validateAirdrop(address memecoin, FuzzParams memory params) internal view {
        // Check our airdrop
        if (params.premineAmount != 0 && params.airdropAmount != 0) {
            // @dev The airdrop count reflects the creator, not the manager
            assertEq(merkleAirdrop.airdropsCount(params.creator), 1);
            assertEq(IERC20(memecoin).balanceOf(address(merkleAirdrop)), params.airdropAmount);
        } else {
            assertEq(merkleAirdrop.airdropsCount(params.creator), 0);
            assertEq(IERC20(memecoin).balanceOf(address(merkleAirdrop)), 0);
        }
    }

    function _validateTreasuryManager(address deployedManager, FuzzParams memory params) internal view {
        // Check our treasury manager
        if (params.manager != address(0)) {
            // The manager should be the owner of the token
            assertEq(flaunch.ownerOf(1), params.manager);

            // The manager should be returned in the flaunch call from the zap
            assertEq(deployedManager, params.manager);

            // if the manager was an approved implementation
            if (treasuryManagerFactory.approvedManagerImplementation(params.manager)) {
                // The permissions should be set on the manager
                assertEq(address(ITreasuryManager(deployedManager).permissions()), params.isClosedPermissions ? address(closedPermissions) : address(whitelistedPermissions));

                // The manager owner should be the creator
                assertEq(ITreasuryManager(deployedManager).managerOwner(), params.creator);
            }
        } else {
            // The creator should be the owner of the token
            assertEq(flaunch.ownerOf(1), params.creator);

            // No manager information should be deployed against the token
            assertEq(deployedManager, address(0));
        }
    }

    function _validateRefundedETH(uint ethSpent) internal view {
        // Check our refunded ETH
        assertEq(payable(address(this)).balance, 1000e27 - ethSpent);
    }

    function test_CanScheduleFlaunchAndPremine(
        uint _initialTokenFairLaunch,
        uint _premineAmount,
        address _creator,
        uint _flaunchAt,
        uint _initialPrice
    ) public {
        // Ensure that the creator is not a zero address, as this will revert
        vm.assume(_creator != address(0));

        // Ensure that our initial token supply is valid (InvalidInitialSupply). We could reference
        // `MAX_FAIR_LAUNCH_TOKENS` directly, but this would be the total supply of the token, which
        // does not make sense for a test. Instead we specify 10% of total supply
        vm.assume(_initialTokenFairLaunch <= 10e27);

        // Ensure that our premine does not exceed the fair launch (PremineExceedsInitialAmount)
        vm.assume(_premineAmount > 0 && _premineAmount <= _initialTokenFairLaunch);

        // Ensure that our flaunch time is in the future
        vm.assume(_flaunchAt > block.timestamp && _flaunchAt <= block.timestamp + 30 days);

        // Provide our user with enough FLETH to make the premine swap
        deal(address(this), 2000e27);
        flETH.deposit{value: 1000e27}();
        flETH.approve(address(flaunchZap), 1000e27);

        // Flaunch time baby!
        (address memecoin_, uint ethSpent_, ) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: PositionManager.FlaunchParams({
                name: 'FlaunchZap',
                symbol: 'ZAP',
                tokenUri: 'ipfs://123',
                initialTokenFairLaunch: _initialTokenFairLaunch,
                fairLaunchDuration: 30 minutes,
                premineAmount: _premineAmount,
                creator: _creator,
                creatorFeeAllocation: 80_00,
                flaunchAt: _flaunchAt,
                initialPriceParams: abi.encode(_initialPrice),
                feeCalculatorParams: abi.encode('')
            }),
            _trustedFeeSigner: address(0),
            _premineSwapHookData: bytes('')
        });

        // Check our refunded ETH
        assertEq(payable(address(this)).balance, 1000e27 - ethSpent_);

        // Jump when in Fair Launch
        vm.warp(_flaunchAt + 1);

        // Check the Fair Launch status
        PoolId poolId = positionManager.poolKey(memecoin_).toId();
        
        // We should only still be in FairLaunch if the premine did not fill the initial fair launch supply
        assertEq(fairLaunch.inFairLaunchWindow(poolId), _premineAmount < _initialTokenFairLaunch);

        // Check Fair Launch allocation
        FairLaunch.FairLaunchInfo memory fairLaunchInfo = fairLaunch.fairLaunchInfo(poolId);
        assertEq(fairLaunchInfo.supply, _initialTokenFairLaunch - _premineAmount);
    }

    function test_CanCalculateFees() public {
        // Set an fee to flaunch
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingFee.selector),
            abi.encode(0.001e18)
        );

        // Set an expected market cap here to in-line with Sepolia tests (2~ eth)
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSelector(PositionManager.getFlaunchingMarketCap.selector),
            abi.encode(2e18)
        );

        // premineCost : 0.1 ether
        // premineCost swap fee : 0.001 ether
        // fee : 0.001 ether

        uint ethRequired = flaunchZap.calculateFee(supplyShare(5_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.1 ether + 0.001 ether + 0.001 ether);

        // premineCost : 0.2 ether
        // premineCost swap fee : 0.002 ether
        // fee : 0.001 ether

        ethRequired = flaunchZap.calculateFee(supplyShare(10_00), 0, abi.encode(''));
        assertEq(ethRequired, 0.2 ether + 0.002 ether + 0.001 ether);
    }

    function test_deployAndInitializeManagerWithPermissions() public {
        address permissionsContract = address(0x789);
        // Deploy a mocked manager implementation
        address managerImplementation = address(new TreasuryManagerMock(address(treasuryManagerFactory)));
        
        treasuryManagerFactory.approveManager(managerImplementation);

        // We know the address in advance for this test, so we can assert the expected value
        vm.expectEmit();
        emit TreasuryManagerFactory.ManagerDeployed(0x514dd0Bcaf5994Ef889f482B79d39D18B6E4363F, managerImplementation);

        // Deploy and initialize the manager with permissions
        address payable _manager = flaunchZap.deployAndInitializeManager(
            managerImplementation,
            address(this),
            abi.encode('Test initialization'),
            permissionsContract
        );

        // Verify the manager was deployed correctly
        assertEq(treasuryManagerFactory.managerImplementation(_manager), managerImplementation);
        
        // Verify the manager was initialized correctly
        TreasuryManagerMock manager = TreasuryManagerMock(_manager);
        assertTrue(manager.initialized());
        assertEq(manager.managerOwner(), address(this));
        
        // Verify permissions were set correctly
        assertEq(address(manager.permissions()), permissionsContract);
    }

    function test_CanFlaunchWithTrustedFeeSigner(
        address _trustedFeeSigner,
        bool _depositIntoManager,
        address _creator,
        uint _initialPrice
    ) public {
        vm.assume(_trustedFeeSigner != address(0));
        vm.assume(_creator != address(0));

        _setupTestEnvironment();

        // Set the TrustedSignerFeeCalculator to the PositionManager
        TrustedSignerFeeCalculator feeCalculator = new TrustedSignerFeeCalculator(address(flETH), address(customFeeManagerRegistry) );
        feeCalculator.grantRole(ProtocolRoles.POSITION_MANAGER, address(positionManager));
        positionManager.setFairLaunchFeeCalculator(feeCalculator);

        // for feeCalculatorParams
        TrustedSignerFeeCalculator.FairLaunchSettings memory settings = TrustedSignerFeeCalculator.FairLaunchSettings({
            enabled: true,
            walletCap: 10 ether,
            txCap: 5 ether
        });

        // for treasuryManagerParams
        address managerImplementation;
        if (_depositIntoManager) {
            // Deploy a mocked manager implementation
            managerImplementation = address(new TreasuryManagerMock(address(treasuryManagerFactory)));
            treasuryManagerFactory.approveManager(managerImplementation);
        }

        (address memecoin_, , address deployedManager_) = flaunchZap.flaunch{value: 1000e27}({
            _flaunchParams: PositionManager.FlaunchParams({
                name: 'FlaunchZap',
                symbol: 'ZAP',
                tokenUri: 'ipfs://123',
                initialTokenFairLaunch: 1e18,
                fairLaunchDuration: 30 minutes,
                premineAmount: 0,
                creator: _creator,
                creatorFeeAllocation: 80_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(_initialPrice),
                feeCalculatorParams: abi.encode(settings)
            }),
            _trustedFeeSigner: _trustedFeeSigner,
            _premineSwapHookData: bytes(''),
            _whitelistParams: FlaunchZap.WhitelistParams({
                merkleRoot: bytes32(''),
                merkleIPFSHash: '',
                maxTokens: 0
            }),
            _airdropParams: FlaunchZap.AirdropParams({
                airdropIndex: 0,
                airdropAmount: 0,
                airdropEndTime: 0,
                merkleRoot: bytes32(''),
                merkleIPFSHash: ''
            }),
            _treasuryManagerParams: FlaunchZap.TreasuryManagerParams({
                manager: managerImplementation,
                permissions: address(0),
                initializeData: abi.encode(''),
                depositData: abi.encode('')
            })
        });

        // Check memecoin creator
        address memecoinCreator = flaunch.ownerOf(1);
        if (_depositIntoManager) {
            assertEq(memecoinCreator, deployedManager_);
        } else {
            assertEq(memecoinCreator, _creator);
        }

        // Check trusted fee signer
        (address signer, bool enabled) = feeCalculator.trustedPoolKeySigner(positionManager.poolKey(memecoin_).toId());
        assertEq(signer, _trustedFeeSigner);
        assertTrue(enabled);
    }
}
