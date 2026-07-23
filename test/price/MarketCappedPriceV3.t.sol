// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';
import {MarketCappedPriceV3} from '@flaunch/price/MarketCappedPriceV3.sol';

import {FlaunchTest} from '../FlaunchTest.sol';

/**
 * @dev `forkBaseBlock` is currently timing out for tests, so they an skipped.
 */
contract MarketCappedPriceV3Test is FlaunchTest {
    address owner = address(this);

    address internal constant ETH_TOKEN = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    MarketCappedPriceV3 internal marketCappedPrice;

    address pool;

    function setUp() public {
        // Deploy our {FlaunchFeeExemption} contract
        flaunchFeeExemption = new FlaunchFeeExemption();

        // Deploy the MarketCappedPrice contract
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Map our Base Uniswap V3 ETH:USDC pool for any fork tests
        pool = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    }

    function test_CanConfirmOwnership() public view {
        // Ensure owner is set correctly
        assertEq(marketCappedPrice.owner(), owner);
    }

    function test_CanSetPool() internal forkBaseBlock(25677808) {
        // As we have forked, we need to make a fresh deployment
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Test the owner can set the pool
        marketCappedPrice.setPool(pool);

        // Confirm pool address is updated
        assertEq(address(marketCappedPrice.pool()), pool);
    }

    function test_CannotSetPoolWithInvalidTokenPair() internal forkBaseBlock(25677808) {
        // As we have forked, we need to make a fresh deployment
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // ETH / TOSHI
        vm.expectRevert(MarketCappedPriceV3.InvalidTokenPair.selector);
        marketCappedPrice.setPool(0x4b0Aaf3EBb163dd45F663b38b6d93f6093EBC2d3);
    }

    function test_CannotSetPoolIfNotOwner(
        address _notOwner
    ) public {
        vm.assume(_notOwner != marketCappedPrice.owner());

        vm.prank(_notOwner);
        vm.expectRevert(UNAUTHORIZED);
        marketCappedPrice.setPool(pool);
    }

    function test_CanGetMarketCap() internal forkBaseBlock(25677808) {
        // As we have forked, we need to make a fresh deployment
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Set our pool
        marketCappedPrice.setPool(pool);

        // Try and get the market cap
        uint marketCap = marketCappedPrice.getMarketCap(abi.encode(5000e6));
        assertEq(marketCap, 1.597265310561477458 ether);
    }

    function test_CanGetLivePool() internal forkBaseBlock(25677808) {
        // As we have forked, we need to make a fresh deployment
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Initial market cap

        marketCappedPrice.setPool(pool);

        uint160 sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(5000e6));
        assertEq(sqrtPriceX96, 19823989265633079175183075819210031);

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), true, abi.encode(5000e6));
        assertEq(sqrtPriceX96, 316641703709388156552902);

        // Update market cap

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(10000e6));
        assertEq(sqrtPriceX96, 14017677239898476663934603372382974);

        sqrtPriceX96 = marketCappedPrice.getSqrtPriceX96(address(this), true, abi.encode(10000e6));
        assertEq(sqrtPriceX96, 447798991798739889617398);
    }

    function test_CanGetPercentageBasedFlaunchingFee() internal forkBaseBlock(25677808) {
        // As we have forked, we need to make a fresh deployment
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Set our pool
        marketCappedPrice.setPool(pool);

        // Our market cap should place the token at $5k~. This means that a 0.01% fee of this
        // should be around $5.
        assertEq(marketCappedPrice.getFlaunchingFee(address(this), abi.encode(5000e6)), 0.001597265310561477 ether);
    }

    function test_CannotGetMarketCapBelowThreshold(
        uint _marketCap
    ) public {
        vm.assume(_marketCap < marketCappedPrice.MINIMUM_USDC_MARKET_CAP());

        vm.expectRevert(
            abi.encodeWithSelector(MarketCappedPriceV3.MarketCapTooSmall.selector, _marketCap, marketCappedPrice.MINIMUM_USDC_MARKET_CAP())
        );

        marketCappedPrice.getSqrtPriceX96(address(this), false, abi.encode(_marketCap));
    }

    function test_CanExcludeFlaunchFee(
        address _excluded,
        address _notExcluded
    ) internal forkBaseBlock(25677808) {
        // Confirm that our addresses are not the same
        vm.assume(_excluded != _notExcluded);

        // Redeploy our {FlaunchFeeExemption} contract due to fork
        flaunchFeeExemption = new FlaunchFeeExemption();

        // Set the pool to allow for flaunching fee calculation
        marketCappedPrice = new MarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));
        marketCappedPrice.setPool(pool);

        // Set some constants for testing
        uint fee = 0.001597265310561477 ether;

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
        emit MarketCappedPriceV3.FlaunchFeeThresholdUpdated(_newFlaunchFeeThreshold);
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
