// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/console.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {MockERC20} from '@uniswap/v4-core/lib/forge-std/src/mocks/MockERC20.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {IndexerSubscriber} from '@flaunch/subscribers/Indexer.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {TrustedSignerFeeCalculator} from '@flaunch/fees/TrustedSignerFeeCalculator.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract IndexerTest is FlaunchTest {

    using PoolIdLibrary for PoolKey;

    // Define our legacy struct
    struct LegacyFlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint initialTokenFairLaunch;
        uint premineAmount;
        address creator;
        uint24 creatorFeeAllocation;
        uint flaunchAt;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }

    constructor () {
        // Deploy our platform
        _deployPlatform();

        // We subscribe our indexer during our test environment setup, so we need to
        // unsubscribe it ahead of our tests
        positionManager.notifier().unsubscribe(address(indexer));
    }

    function test_CanIndex() public {
        _deploySubscriber();
        _setNotifier();

        (address memecoin, uint tokenId, PoolKey memory poolKey) = _flaunchToken();

        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin);
        assertEq(indexedTokenId, tokenId);
    }

    function test_CannotIndexWithoutNotifierFlaunch() public {
        (,, PoolKey memory poolKey) = _flaunchToken();
        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());
        assertEq(indexedFlaunch, address(0));
        assertEq(indexedMemecoin, address(0));
        assertEq(indexedTokenId, 0);
    }

    function test_CanAddIndex() public {
        (address memecoin1, uint tokenId1, PoolKey memory poolKey1) = _flaunchToken();
        (address memecoin2, uint tokenId2, PoolKey memory poolKey2) = _flaunchToken();

        _deploySubscriber();
        _setNotifier();

        IndexerSubscriber.AddIndexParams[] memory indexParams = new IndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        indexParams[0] = IndexerSubscriber.AddIndexParams({
            flaunch: address(flaunch),
            tokenIds: tokenIds
        });

        indexer.addIndex(indexParams);

        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey1.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin1);
        assertEq(indexedTokenId, tokenId1);

        (indexedFlaunch, indexedMemecoin,, indexedTokenId) = indexer.poolIndex(poolKey2.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin2);
        assertEq(indexedTokenId, tokenId2);
    }

    function test_CanIndexDeletedToken() public {
        // Ensure that our indexer is set up correctly
        _deploySubscriber();
        _setNotifier();

        // Create our base token
        (address memecoin, uint tokenId, PoolKey memory poolKey) = _flaunchToken();

        // Burn the token
        flaunch.burn(tokenId);

        // Get the poolIndex information from the indexer
        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());

        // We should expect the usual information, but the tokenId should be 0 as it was burned
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin);
        assertEq(indexedTokenId, 0);
    }

    function testFork_IndexCorrectly() public forkBaseBlock(35_654_101) {
        address[] memory positionManagers = new address[](3);
        positionManagers[0] = 0xF785bb58059FAB6fb19bDdA2CB9078d9E546Efdc;
        positionManagers[1] = 0xB903b0AB7Bcee8f5E4D8C9b10a71aaC7135d6FdC;
        positionManagers[2] = 0x23321f11a6d44Fd1ab790044FdFDE5758c902FDc;

        address[] memory anyPositionManagers = new address[](1);
        anyPositionManagers[0] = 0x8DC3b85e1dc1C846ebf3971179a751896842e5dC;

        // Register our indexer
        IndexerSubscriber indexer = IndexerSubscriber(0x7C6088C1185FbB770deB1CA7DdeeD4ba57659663);

        // Iterate over the position managers we are testing
        for (uint i = 0; i < positionManagers.length; ++i) {
            console.log('Testing PositionManager:', positionManagers[i]);

            // Register the PositionManager
            PositionManager positionManager = PositionManager(payable(positionManagers[i]));

            // Set our calculators to boring static ones for simpler, generalized transactions
            vm.startPrank(positionManager.owner());
            positionManager.setFeeCalculator(IFeeCalculator(0xaA27191eB96F8C9F1f50519C53e6512228f2faB9));
            positionManager.setFairLaunchFeeCalculator(IFeeCalculator(0xaA27191eB96F8C9F1f50519C53e6512228f2faB9));
            positionManager.setInitialPrice(0xf318E170D10A1F0d9b57211e908a7f081123E7f6);
            vm.stopPrank();

            // Flaunch a token. The configuration doesn't really matter, we just need to ensure that it is indexed correctly.
            address memecoin = positionManager.flaunch(
                PositionManager.FlaunchParams({
                    name: 'name',
                    symbol: 'symbol',
                    tokenUri: 'https://token.gg/',
                    initialTokenFairLaunch: supplyShare(50),
                    fairLaunchDuration: 30 minutes,
                    premineAmount: 0,
                    creator: address(this),
                    creatorFeeAllocation: 50_00,
                    flaunchAt: block.timestamp,
                    initialPriceParams: abi.encode(1000e6),
                    feeCalculatorParams: abi.encode(false, 0, 0)
                })
            );

            // Get the poolKey for the token
            PoolKey memory poolKey = positionManager.poolKey(memecoin);

            // Validate the PoolKey by checking the currency1 matches the memecoin
            assertEq(Currency.unwrap(poolKey.currency1), memecoin);

            // Get the poolIndex information from the indexer
            (address indexedFlaunch, address indexedMemecoin,,) = indexer.poolIndex(poolKey.toId());
            assertEq(indexedFlaunch, address(positionManager.flaunchContract()));
            assertEq(indexedMemecoin, memecoin);
        }

        // Iterate over the AnyPositionManagers we are testing
        for (uint i = 0; i < anyPositionManagers.length; ++i) {
            console.log('Testing AnyPositionManager:', anyPositionManagers[i]);

            // Set up a MockERC20 token to whitelist and test flaunching with
            MockERC20 newToken = new MockERC20();
            newToken.initialize('name', 'symbol', 18);
            address memecoin = address(newToken);

            // Register the PositionManager
            AnyPositionManager positionManager = AnyPositionManager(payable(anyPositionManagers[i]));

            vm.prank(positionManager.owner());
            positionManager.approveCreator(address(this), true);

            // Set our calculators to boring static ones for simpler, generalized transactions
            vm.startPrank(positionManager.owner());
            positionManager.setFeeCalculator(IFeeCalculator(0xaA27191eB96F8C9F1f50519C53e6512228f2faB9));
            positionManager.setInitialPrice(0xf318E170D10A1F0d9b57211e908a7f081123E7f6);
            vm.stopPrank();

            // Flaunch a token. The configuration doesn't really matter, we just need to ensure that it is indexed correctly.
            positionManager.flaunch(
                AnyPositionManager.FlaunchParams(
                    memecoin,
                    address(this),
                    50_00,
                    abi.encode(1000e6),
                    abi.encode(false, 0, 0)
                )
            );

            // Get the poolKey for the token
            PoolKey memory poolKey = positionManager.poolKey(memecoin);

            // Validate the PoolKey by checking the currency1 matches the memecoin
            assertEq(Currency.unwrap(poolKey.currency1), memecoin);

            // Get the poolIndex information from the indexer
            (address indexedFlaunch, address indexedMemecoin,,) = indexer.poolIndex(poolKey.toId());
            assertEq(indexedFlaunch, address(positionManager.flaunchContract()));
            assertEq(indexedMemecoin, memecoin);
        }
    }

    function _deploySubscriber() internal {
        positionManager.notifier().subscribe(address(indexer), '');
    }

    function _setNotifier() internal {
        indexer.setNotifierFlaunch(address(positionManager.notifier()), address(flaunch));
    }

    function _flaunchToken() internal returns (address memecoin_, uint tokenId_, PoolKey memory poolKey_) {
        memecoin_ = positionManager.flaunch(PositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', supplyShare(50), 30 minutes, 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)));
        tokenId_ = flaunch.tokenId(memecoin_);
        poolKey_ = PoolKey({
            currency0: Currency.wrap(address(flETH)),
            currency1: Currency.wrap(memecoin_),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });
    }

}
