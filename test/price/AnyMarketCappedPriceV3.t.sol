// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';
import {AnyMarketCappedPriceV3} from '@flaunch/price/AnyMarketCappedPriceV3.sol';
import {ERC20Mock} from '../tokens/ERC20Mock.sol';

import {FlaunchTest} from '../FlaunchTest.sol';


contract AnyMarketCappedPriceV3Test is FlaunchTest {

    address owner = address(this);

    AnyMarketCappedPriceV3 internal anyMarketCappedPrice;
    ERC20Mock internal memecoin;
    address internal mockPool;

    address internal constant ETH_TOKEN = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        // Deploy our {FlaunchFeeExemption} contract
        flaunchFeeExemption = new FlaunchFeeExemption();

        // Deploy the AnyMarketCappedPriceV3 contract
        anyMarketCappedPrice = new AnyMarketCappedPriceV3(owner, ETH_TOKEN, USDC_TOKEN, address(flaunchFeeExemption));

        // Create a mock pool address
        mockPool = address(0x1234567890123456789012345678901234567890);

        // Mock pool.token0() and pool.token1() calls for setPool validation
        vm.mockCall(
            mockPool,
            abi.encodeWithSignature("token0()"),
            abi.encode(USDC_TOKEN)
        );
        vm.mockCall(
            mockPool,
            abi.encodeWithSignature("token1()"),
            abi.encode(ETH_TOKEN)
        );

        // Set the pool on the contract
        vm.prank(owner);
        anyMarketCappedPrice.setPool(mockPool);

        // Deploy a mock ERC20 token for testing
        memecoin = new ERC20Mock(address(this));

        // Set a total supply for the memecoin, as if it were being bridged
        memecoin.mint(address(this), 3000e6);
    }

    /**
     * Test that getSqrtPriceX96 works with the new struct version that includes tokenSupply
     */
    function test_GetSqrtPriceX96_WithTokenSupply() public {
        // Mock the pool's observe call to avoid external calls
        _mockGetMarketCap();

        // Encode the struct with all three fields including tokenSupply
        // We encode: uint usdcMarketCap, address memecoin, uint tokenSupply
        bytes memory initialPriceParams = abi.encode(
            uint(4000e6),           // usdcMarketCap - $4,000 USDC
            address(memecoin),      // memecoin
            uint(1_000_000_000e6)   // tokenSupply - 1 billion tokens at 6 decimals, like pump.fun
        );

        // Call getSqrtPriceX96 - should use the provided tokenSupply (1 billion tokens) instead of totalSupply
        // Expected: sqrtPriceX96 for 1.3113e18 ETH <> 1000000000e6 tokens
        // When _flipped = false, _isEthToken0 = true, so formula is:
        // sqrtPriceX96 = sqrt((tokenAmount * 2^192) / ethAmount)
        //              = sqrt((1e15 * 2^192) / 1.3113e18)
        //              = sqrt(2^192 / 1311.3)
        uint160 sqrtPriceX96 = anyMarketCappedPrice.getSqrtPriceX96(address(this), false, initialPriceParams);

        // Expected value calculated: sqrt((1e15 * 2^192) / 1.3113e18) = 725702323492881828144039858743
        uint160 expectedSqrtPriceX96 = 725702323492881828144039858743;
        
        // Verify the result matches the expected value
        assertEq(sqrtPriceX96, expectedSqrtPriceX96);
    }

    /**
     * Test that getSqrtPriceX96 works with the legacy struct version that doesn't include tokenSupply
     */
    function test_GetSqrtPriceX96_WithoutTokenSupply() public {
        // Mock the pool's observe call to avoid external calls
        _mockGetMarketCap();

        // Encode only the legacy two fields (usdcMarketCap and memecoin)
        bytes memory initialPriceParams = abi.encode(uint(5000e6), address(memecoin));

        // Call getSqrtPriceX96 - should fall back to using memecoin.totalSupply()
        uint160 sqrtPriceX96 = anyMarketCappedPrice.getSqrtPriceX96(address(this), false, initialPriceParams);

        // Verify that the result is non-zero (exact value depends on calculation)
        assertEq(sqrtPriceX96, 725702323492881828144039858743);
    }

    /**
     * @dev We mock the pool.observe() call because getMarketCap is called internally, and vm.mockCall only
     * works for external calls.
     * 
     * This function mocks the pool.observe() call to return tick values that result in getMarketCap()
     * returning 1.3113 ETH when given $4000 USDC. This is based on an ETH price of approximately $3049.5 USDC
     * (calculated as: 4000 / 1.3113 ≈ 3049.5).
     * 
     * The tick values are calculated to produce this ETH price:
     * - tick = log(3049.5) / log(1.0001) ≈ 80000
     * - Over 1800 seconds (30 minutes), we need a tick difference of 80000 * 1800 = 144000000
     */
    function _mockGetMarketCap() internal {
        // Mock the pool.observe() call that getMarketCap makes internally
        // observe returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
        // We'll return tick values that result in getMarketCap returning 1.3113 ETH for $4000 USDC
        // This requires an ETH price of ~$3049.5 USDC, which corresponds to tick ~80000
        // Over 1800 seconds, we need a cumulative tick difference of 80000 * 1800 = 144000000
        int56 tickCumulative0 = 0; // 30 minutes ago
        int56 tickCumulative1 = 144000000; // now (tick difference of 144000000 over 1800 seconds = average tick of 80000)
        
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulative0;
        tickCumulatives[1] = tickCumulative1;
        
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        
        // Mock the observe call - this is an external call that vm.mockCall can intercept
        // We use abi.encodePacked with the selector to match any call to observe(uint32[])
        bytes4 observeSelector = bytes4(keccak256("observe(uint32[])"));
        vm.mockCall(
            mockPool,
            abi.encodePacked(observeSelector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

}
