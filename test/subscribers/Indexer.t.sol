// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import 'forge-std/console.sol';

import {MockERC20} from '@uniswap/v4-core/lib/forge-std/src/mocks/MockERC20.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TrustedSignerFeeCalculator} from '@flaunch/fees/TrustedSignerFeeCalculator.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {IndexerSubscriber} from '@flaunch/subscribers/Indexer.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IIndexerSubscriber} from '@flaunch-interfaces/IIndexerSubscriber.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IAnyPositionManager} from '@flaunch-interfaces/IAnyPositionManager.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

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

    constructor() {
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

        IIndexerSubscriber.AddIndexParams[] memory indexParams = new IIndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        indexParams[0] = IIndexerSubscriber.AddIndexParams({flaunch: address(flaunch), tokenIds: tokenIds});

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

    function _deploySubscriber() internal {
        positionManager.notifier().subscribe(address(indexer), '');
    }

    function _setNotifier() internal {
        indexer.setNotifierFlaunch(address(positionManager.notifier()), address(flaunch));
    }

    function _flaunchToken() internal returns (address memecoin_, uint tokenId_, PoolKey memory poolKey_) {
        memecoin_ = positionManager.flaunch(
            IPositionManager.FlaunchParams(
                'name', 'symbol', 'https://token.gg/', 0, address(this), 50_00, 0, abi.encode(''), abi.encode(1_000)
            )
        );
        tokenId_ = flaunch.tokenId(memecoin_);
        poolKey_ = PoolKey({
            currency0: Currency.wrap(address(flETH)),
            currency1: Currency.wrap(memecoin_),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(positionManager))
        });
    }

    function test_CanAddVerifiedFlaunch() public {
        address testFlaunch = address(0x1234);

        // Initially should not be verified
        assertEq(indexer.isVerifiedFlaunch(testFlaunch), false, 'Flaunch should not be verified initially');

        // Expect the FlaunchVerified event to be emitted
        vm.expectEmit();
        emit IIndexerSubscriber.FlaunchVerified(testFlaunch, true);

        // Add the verified flaunch as owner
        indexer.addVerifiedFlaunch(testFlaunch);

        // Verify it was added
        assertEq(indexer.isVerifiedFlaunch(testFlaunch), true, 'Flaunch should be verified after adding');
    }

    function test_CanRemoveVerifiedFlaunch() public {
        address testFlaunch = address(0x1234);

        // First add it
        indexer.addVerifiedFlaunch(testFlaunch);
        assertEq(indexer.isVerifiedFlaunch(testFlaunch), true, 'Flaunch should be verified after adding');

        // Expect the FlaunchVerified event to be emitted with false
        vm.expectEmit();
        emit IIndexerSubscriber.FlaunchVerified(testFlaunch, false);

        // Remove the verified flaunch as owner
        indexer.removeVerifiedFlaunch(testFlaunch);

        // Verify it was removed
        assertEq(indexer.isVerifiedFlaunch(testFlaunch), false, 'Flaunch should not be verified after removing');

        // Also verify it was removed by trying to use it in addIndex - it should revert
        IIndexerSubscriber.AddIndexParams[] memory indexParams = new IIndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 1;
        indexParams[0] = IIndexerSubscriber.AddIndexParams({flaunch: testFlaunch, tokenIds: tokenIds});

        vm.expectRevert(abi.encodeWithSelector(IIndexerSubscriber.FlaunchNotVerified.selector, testFlaunch));
        indexer.addIndex(indexParams);
    }

    function test_CannotAddVerifiedFlaunchAsNonOwner() public {
        address testFlaunch = address(0x1234);
        address nonOwner = address(0x5678);

        // Try to add as non-owner - should revert with Unauthorized
        vm.prank(nonOwner);
        vm.expectRevert();
        indexer.addVerifiedFlaunch(testFlaunch);
    }

    function test_CannotRemoveVerifiedFlaunchAsNonOwner() public {
        address testFlaunch = address(0x1234);

        // First add it as owner
        indexer.addVerifiedFlaunch(testFlaunch);

        // Try to remove as non-owner - should revert with Unauthorized
        address nonOwner = address(0x5678);
        vm.prank(nonOwner);
        vm.expectRevert();
        indexer.removeVerifiedFlaunch(testFlaunch);
    }

    function test_CannotIndexAgainstUnverifiedFlaunch() public {
        // Create a real token to get valid data
        (address memecoin, uint tokenId, PoolKey memory poolKey) = _flaunchToken();

        // Create an unverified Flaunch contract address
        address unverifiedFlaunch = address(0x9999);

        // Verify it's not verified
        assertEq(indexer.isVerifiedFlaunch(unverifiedFlaunch), false, 'Flaunch should not be verified');

        // Try to add index with unverified flaunch - should revert
        IIndexerSubscriber.AddIndexParams[] memory indexParams = new IIndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = tokenId;
        indexParams[0] = IIndexerSubscriber.AddIndexParams({flaunch: unverifiedFlaunch, tokenIds: tokenIds});

        vm.expectRevert(abi.encodeWithSelector(IIndexerSubscriber.FlaunchNotVerified.selector, unverifiedFlaunch));
        indexer.addIndex(indexParams);
    }

    function test_CanIndexAgainstVerifiedFlaunch() public {
        // Create a real token to get valid data
        (address memecoin, uint tokenId, PoolKey memory poolKey) = _flaunchToken();

        // Verify the flaunch contract
        indexer.addVerifiedFlaunch(address(flaunch));
        assertEq(indexer.isVerifiedFlaunch(address(flaunch)), true, 'Flaunch should be verified');

        // Now add index should work
        IIndexerSubscriber.AddIndexParams[] memory indexParams = new IIndexerSubscriber.AddIndexParams[](1);
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = tokenId;
        indexParams[0] = IIndexerSubscriber.AddIndexParams({flaunch: address(flaunch), tokenIds: tokenIds});

        // Expect PoolIndexed event
        vm.expectEmit();
        emit IIndexerSubscriber.PoolIndexed(poolKey.toId(), address(flaunch), memecoin, flaunch.memecoinTreasury(tokenId), tokenId);

        indexer.addIndex(indexParams);

        // Verify it was indexed
        (address indexedFlaunch, address indexedMemecoin,, uint indexedTokenId) = indexer.poolIndex(poolKey.toId());
        assertEq(indexedFlaunch, address(flaunch));
        assertEq(indexedMemecoin, memecoin);
        assertEq(indexedTokenId, tokenId);
    }
}
