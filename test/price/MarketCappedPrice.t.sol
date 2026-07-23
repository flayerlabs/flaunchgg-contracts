// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';
import {MarketCappedPrice} from '@flaunch/price/MarketCappedPrice.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

/**
 * @dev `forkBaseSepoliaBlock` is currently timing out for tests, so they an skipped.
 */
contract MarketCappedPriceTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    address owner = address(this);

    address internal constant ETH_TOKEN = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_TOKEN = 0x5d7fbE8a713bE0Cb6E177EB7028A9b0CA370AafC;

    MarketCappedPrice marketCappedPrice;

    PoolId poolId;
    PoolKey poolKey;

    function setUp() public {
        // Deploy our {FlaunchFeeExemption} contract
        flaunchFeeExemption = new FlaunchFeeExemption();

        // Deploy the MarketCappedPrice contract
        marketCappedPrice = new MarketCappedPrice(owner, address(poolManager), ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Map our Base Sepolia ETH:USDC pool for any fork tests
        poolKey = PoolKey({
            currency0: Currency.wrap(ETH_TOKEN), currency1: Currency.wrap(USDC_TOKEN), fee: 3_00, tickSpacing: 60, hooks: IHooks(address(0))
        });

        poolId = poolKey.toId();
    }

    function test_CanConfirmOwnership() public view {
        // Ensure owner is set correctly
        assertEq(marketCappedPrice.owner(), owner);
    }

    function test_CanSetPool() public {
        // Test the owner can set the PoolId
        marketCappedPrice.setPool(poolKey);

        // Confirm PoolId is updated
        assertEq(PoolId.unwrap(marketCappedPrice.poolId()), PoolId.unwrap(poolId));
    }

    function test_CannotSetPoolWithInvalidTokenPair(
        address _token0,
        address _token1
    ) public {
        // Ensure that at least one of the tokens does not match
        vm.assume((_token0 != ETH_TOKEN && _token0 != USDC_TOKEN) || (_token1 != ETH_TOKEN && _token1 != USDC_TOKEN));

        poolKey = PoolKey({
            currency0: Currency.wrap(_token0), currency1: Currency.wrap(_token1), fee: 3_00, tickSpacing: 60, hooks: IHooks(address(0))
        });

        vm.expectRevert('Invalid token pair');
        marketCappedPrice.setPool(poolKey);
    }

    function test_CannotSetPoolIfNotOwner(
        address _notOwner
    ) public {
        vm.assume(_notOwner != marketCappedPrice.owner());

        vm.prank(_notOwner);
        vm.expectRevert(UNAUTHORIZED);
        marketCappedPrice.setPool(poolKey);
    }

    function test_CanGetMarketCap() internal forkBaseSepoliaBlock(17017447) {
        // As we have forked, we need to make a fresh deployment. We also need to reference
        // the Sepolia deployment of the {PoolManager}.
        marketCappedPrice =
            new MarketCappedPrice(owner, 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Set our PoolId
        marketCappedPrice.setPool(poolKey);

        // Set our market cap at $5,000
        // marketCappedPrice.setMarketCap(5000e6);

        // Try and get the market cap
        uint marketCap = marketCappedPrice.getMarketCap(abi.encode(5000e6));
        assertEq(marketCap, 1.923076923816568047 ether);
    }

    function test_CanGetLivePool() internal forkBaseSepoliaBlock(17017447) {
        poolKey = PoolKey({
            currency0: Currency.wrap(ETH_TOKEN), currency1: Currency.wrap(USDC_TOKEN), fee: 3_00, tickSpacing: 60, hooks: IHooks(address(0))
        });

        marketCappedPrice =
            new MarketCappedPrice(owner, 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Initial market cap

        marketCappedPrice.setPool(poolKey);

        uint160 sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(5000e6));
        assertEq(sqrtPriceX96, 18066800771430601158259558888817622);

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), true, abi.encode(5000e6));
        assertEq(sqrtPriceX96, 347438476507295590049312);

        // Update market cap

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(10000e6));
        assertEq(sqrtPriceX96, 12775157339824926106004661609217630);

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), true, abi.encode(10000e6));
        assertEq(sqrtPriceX96, 491352205566863390802479);
    }

    function test_CanGetPercentageBasedFlaunchingFee() internal forkBaseSepoliaBlock(17017447) {
        // As we have forked, we need to make a fresh deployment. We also need to reference
        // the Sepolia deployment of the {PoolManager}.
        marketCappedPrice =
            new MarketCappedPrice(owner, 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Set our PoolId
        marketCappedPrice.setPool(poolKey);

        // Our market cap should place the token at $5k~. This means that a 0.01% fee of this
        // should be around $5.
        assertEq(marketCappedPrice.getFlaunchingFee(address(this), abi.encode(5000e6)), 0.001923076923816568 ether);
    }

    function test_CannotGetMarketCapBelowThreshold(
        uint _marketCap
    ) public {
        vm.assume(_marketCap < marketCappedPrice.MINIMUM_USDC_MARKET_CAP());

        vm.expectRevert(
            abi.encodeWithSelector(MarketCappedPrice.MarketCapTooSmall.selector, _marketCap, marketCappedPrice.MINIMUM_USDC_MARKET_CAP())
        );

        marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(_marketCap));
    }

    function test_CanExcludeFlaunchFee(
        address _excluded,
        address _notExcluded
    ) internal forkBaseSepoliaBlock(17017447) {
        // Confirm that our addresses are not the same
        vm.assume(_excluded != _notExcluded);

        // Redeploy our {FlaunchFeeExemption} contract due to fork
        flaunchFeeExemption = new FlaunchFeeExemption();

        // Set the pool to allow for flaunching fee calculation
        marketCappedPrice =
            new MarketCappedPrice(owner, 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));
        marketCappedPrice.setPool(poolKey);

        // Set some constants for testing
        uint fee = 0.001923076923816568 ether;

        // Set a fee exclusion for an address
        marketCappedPrice.flaunchFeeExemption().setFeeExemption(_excluded, true);

        // Confirm that the flaunch fee is now zero
        assertEq(marketCappedPrice.getFlaunchingFee(_excluded, abi.encode(5000e6)), 0);

        // Confirm that the other address still has a fee
        assertEq(marketCappedPrice.getFlaunchingFee(_notExcluded, abi.encode(5000e6)), fee);

        // Update the fee exclusion
        marketCappedPrice.flaunchFeeExemption().setFeeExemption(_excluded, false);

        // Confirm that the user now has a fee to pay
        assertEq(marketCappedPrice.getFlaunchingFee(_excluded, abi.encode(5000e6)), fee);
    }

    function test_CanSetFlaunchFeeThreshold(
        uint _newFlaunchFeeThreshold
    ) public {
        vm.expectEmit();
        emit MarketCappedPrice.FlaunchFeeThresholdUpdated(_newFlaunchFeeThreshold);
        marketCappedPrice.setFlaunchFeeThreshold(_newFlaunchFeeThreshold);

        assertEq(marketCappedPrice.flaunchFeeThreshold(), _newFlaunchFeeThreshold);
    }

    function test_CannotSetFlaunchFeeThresholdIfNotOwner(
        address _caller,
        uint _newFlaunchFeeThreshold
    ) public {
        vm.assume(_caller != owner);

        vm.startPrank(_caller);

        vm.expectRevert(UNAUTHORIZED);
        marketCappedPrice.setFlaunchFeeThreshold(_newFlaunchFeeThreshold);

        vm.stopPrank();
    }
}
