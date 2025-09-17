// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';

import {BuyBackManager} from '@flaunch/treasury/managers/BuyBackManager.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeSplitManager} from '@flaunch/treasury/managers/FeeSplitManager.sol';
import {SupportsCreatorTokens} from '@flaunch/treasury/managers/SupportsCreatorTokens.sol';
import {SupportsOwnerFees} from '@flaunch/treasury/managers/SupportsOwnerFees.sol';
import {TreasuryManagerFactory} from '@flaunch/treasury/managers/TreasuryManagerFactory.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract BuyBackManagerTest is FlaunchTest {

    // The treasury manager
    BuyBackManager managerImplementation;

    address mockToken;

    uint public constant MAX_SHARE = 100_00000;

    bytes internal constant EMPTY_BYTES = abi.encode('');

    PoolKey public buyBackPoolKey;

    function setUp() public {
        _deployPlatform();

        // Deploy the BuyBackManager implementation
        managerImplementation = new BuyBackManager(
            address(treasuryManagerFactory),
            address(poolManager),
            address(bidWall),
            address(flETH)
        );

        // Approve the BuyBackManager implementation
        treasuryManagerFactory.approveManager(address(managerImplementation));

        // Set the implementation as a PositionManager on the BidWall
        bidWall.grantRole(ProtocolRoles.POSITION_MANAGER, address(managerImplementation));

        // Deploy a mock token
        mockToken = positionManager.flaunch(
            PositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                initialTokenFairLaunch: 0,
                fairLaunchDuration: 0,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 100_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Set the buyBackPoolKey
        buyBackPoolKey = positionManager.poolKey(mockToken);
    }

    function test_CanInitialize(uint _creatorShare, uint _ownerShare) public {
        _assumeShares(_creatorShare, _ownerShare);

        BuyBackManager buyBackManager = _deployManager(_creatorShare, _ownerShare, buyBackPoolKey);

        // Confirm our immutable attributes
        assertEq(address(buyBackManager.buyBackContract()), address(managerImplementation), 'Invalid buyBackContract');
        assertEq(address(buyBackManager.poolManager()), address(poolManager), 'Invalid poolManager');
        assertEq(address(buyBackManager.bidWall()), address(bidWall), 'Invalid bidWall');
        assertEq(address(Currency.unwrap(buyBackManager.flETH())), address(flETH), 'Invalid flETH');

        // Confirm our initialized attributes
        assertEq(buyBackManager.creatorShare(), _creatorShare, 'Invalid creatorShare');
        assertEq(buyBackManager.ownerShare(), _ownerShare, 'Invalid ownerShare');

        (Currency currency0, Currency currency1, uint fee, int24 tickSpacing, IHooks hooks) = buyBackManager.buyBackPoolKey();
        assertEq(Currency.unwrap(currency0), address(flETH), 'Invalid currency0');
        assertEq(Currency.unwrap(currency1), address(mockToken), 'Invalid currency1');
        assertEq(fee, 0, 'Invalid fee');
        assertEq(tickSpacing, 60, 'Invalid tickSpacing');
        assertEq(address(hooks), address(positionManager), 'Invalid hooks');
    }

    function test_CannotInitializeWithInvalidCreatorShare(uint _invalidShare) public {
        vm.assume(_invalidShare > MAX_SHARE);

        vm.expectRevert(abi.encodeWithSelector(SupportsCreatorTokens.InvalidCreatorShare.selector));
        _deployManager(_invalidShare, 0, buyBackPoolKey);
    }

    function test_CannotInitializeWithInvalidOwnerShare(uint _invalidShare) public {
        vm.assume(_invalidShare > MAX_SHARE);

        vm.expectRevert(abi.encodeWithSelector(SupportsOwnerFees.InvalidOwnerShare.selector));
        _deployManager(0, _invalidShare, buyBackPoolKey);
    }

    function test_CannotInitializeWithInvalidCombinedShare(uint _creatorShare, uint _ownerShare) public {
        // Bind our individual shares to be under 100%, but for the combined share to be over 100%
        _creatorShare = bound(_creatorShare, MAX_SHARE / 2 + 1, MAX_SHARE);
        _ownerShare = bound(_ownerShare, MAX_SHARE / 2 + 1, MAX_SHARE);

        // Ensure that the combined share is above 100%
        vm.assume(_creatorShare + _ownerShare > MAX_SHARE);

        // Initialize our token
        vm.expectRevert(abi.encodeWithSelector(FeeSplitManager.InvalidShareTotal.selector));
        _deployManager(_creatorShare, _ownerShare, buyBackPoolKey);
    }

    function test_CanRouteBuyBack(uint _amount) public {
        // Ensure that the amount is not going to overflow liquidity
        vm.assume(_amount < type(uint32).max);

        // Deploy a BuyBackManager
        BuyBackManager buyBackManager = _deployManager(0, 0, buyBackPoolKey);

        // Allocate some fees
        _allocateFees(buyBackManager, _amount);

        // Route our BuyBack via the implementation into the BidWall
        uint amount = buyBackManager.routeBuyBack();
        assertEq(amount, _amount, 'Invalid amount routed');

        // Check that the BidWall received the amount by looking at the cumulative swap
        // fees stored against the BidWall PoolInfo.
        (,,,,, uint cumulativeSwapFees) = bidWall.poolInfo(buyBackPoolKey.toId());
        assertEq(cumulativeSwapFees, _amount, 'Invalid amount received');
    }

    function test_CannotDirectlyBuyBack() public {
        // Checks that we cannot directly call the `buyBack` function on the implementation
        vm.expectRevert(abi.encodeWithSelector(BuyBackManager.InvalidImplementation.selector));
        managerImplementation.buyBack{value: 100}(buyBackPoolKey);

        // Checks that we cannot directly call the `buyBack` function on the deployed manager
        BuyBackManager buyBackManager = _deployManager(0, 0, buyBackPoolKey);
        vm.expectRevert(abi.encodeWithSelector(BuyBackManager.InvalidImplementation.selector));
        buyBackManager.buyBack{value: 100}(buyBackPoolKey);
    }

    function test_CannotRouteBuyBackOnInitialImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(BuyBackManager.InvalidImplementation.selector));
        managerImplementation.routeBuyBack();
    }

    function _deployManager(uint _creatorShare, uint _ownerShare, PoolKey memory _buyBackPoolKey) internal returns (BuyBackManager manager_) {
        // Initialize our token
        address payable manager = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: address(managerImplementation),
            _owner: address(this),
            _data: abi.encode(
                BuyBackManager.InitializeParams(_creatorShare, _ownerShare, _buyBackPoolKey)
            )
        });

        manager_ = BuyBackManager(manager);
    }

    function _allocateFees(BuyBackManager _buyBackManager, uint _amount) internal {
        // Mint ETH to the flETH contract to facilitate unwrapping
        deal(address(this), _amount);
        WETH.deposit{value: _amount}();
        WETH.transfer(address(positionManager), _amount);

        positionManager.allocateFeesMock({
            _poolId: PoolId.wrap(bytes32('1')),  // Can be mocked to anything
            _recipient: payable(address(_buyBackManager)),
            _amount: _amount
        });
    }

    function _assumeShares(uint _creatorShare, uint _ownerShare) internal {
        vm.assume(_creatorShare <= MAX_SHARE);
        vm.assume(_ownerShare <= MAX_SHARE);
        vm.assume(_creatorShare + _ownerShare <= MAX_SHARE);
    }
}
