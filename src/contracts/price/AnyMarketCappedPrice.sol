// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MarketCappedPrice} from '@flaunch/price/MarketCappedPrice.sol';

/**
 * This contract defines an initial flaunch price by finding the ETH equivalent price of
 * a USDC value. This is done by checking the an ETH:USDC pool to find an ETH price of an
 * Owner defined USDC price.
 *
 * Supports external memecoins with varying total supply.
 *
 * This ETH equivalent price is then cast against the memecoin supply to determine market
 * cap.
 */
contract AnyMarketCappedPrice is MarketCappedPrice {
    /**
     * The struct of data that should be passed from the flaunching flow to define the
     * desired market cap when a token is flaunching.
     *
     * @member usdcMarketCap The USDC price of the token market cap
     * @member memecoin The address of the memecoin being flaunched
     */
    struct AnyMarketCappedPriceParams {
        uint usdcMarketCap;
        address memecoin;
    }

    /**
     * Sets the owner of this contract that will be allowed to update the pool.
     *
     * @param _protocolOwner The address of the owner
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _ethToken The ETH token used in the Pool
     * @param _usdcToken The USDC token used in the Pool
     * @param _flaunchFeeExemption The {FlaunchFeeExemption} contract address
     */
    constructor(
        address _protocolOwner,
        address _poolManager,
        address _ethToken,
        address _usdcToken,
        address _flaunchFeeExemption
    ) MarketCappedPrice(_protocolOwner, _poolManager, _ethToken, _usdcToken, _flaunchFeeExemption) {}

    /**
     * Retrieves the stored `_initialSqrtPriceX96` value and provides the flipped or unflipped
     * `sqrtPriceX96` value.
     *
     * @param _flipped If the PoolKey currencies are flipped
     * @param _initialPriceParams Parameters for the initial pricing
     *
     * @return sqrtPriceX96_ The `sqrtPriceX96` value
     */
    function getSqrtPriceX96(
        address,
        /* _sender */
        bool _flipped,
        bytes calldata _initialPriceParams
    ) public view override returns (uint160 sqrtPriceX96_) {
        (AnyMarketCappedPriceParams memory params) = abi.decode(_initialPriceParams, (AnyMarketCappedPriceParams));

        uint totalSupply = IERC20(params.memecoin).totalSupply();

        return _calculateSqrtPriceX96(getMarketCap(_initialPriceParams), totalSupply, !_flipped);
    }
}
