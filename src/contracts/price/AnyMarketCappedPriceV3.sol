// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MarketCappedPriceV3} from '@flaunch/price/MarketCappedPriceV3.sol';

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
contract AnyMarketCappedPriceV3 is MarketCappedPriceV3 {

    /**
     * The struct of data that should be passed from the flaunching flow to define the
     * desired market cap when a token is flaunching.
     *
     * @dev The tokenSupply should be provided in the decimal accuracy of the token on Base,
     * with the amount held on the source chain's token.
     *
     * @member usdcMarketCap The USDC price of the token market cap
     * @member memecoin The address of the memecoin being flaunched
     * @member tokenSupply An optional override for the default token total supply
     */
    struct AnyMarketCappedPriceParams {
        uint usdcMarketCap;
        address memecoin;
        uint tokenSupply;
    }

    /**
     * Sets the owner of this contract that will be allowed to update the pool.
     *
     * @param _protocolOwner The address of the owner
     * @param _ethToken The ETH token used in the Pool
     * @param _usdcToken The USDC token used in the Pool
     * @param _flaunchFeeExemption The {FlaunchFeeExemption} contract address
     */
    constructor (
        address _protocolOwner,
        address _ethToken,
        address _usdcToken,
        address _flaunchFeeExemption
    ) MarketCappedPriceV3(
        _protocolOwner,
        _ethToken,
        _usdcToken,
        _flaunchFeeExemption
    ) {}

    /**
     * Retrieves the stored `_initialSqrtPriceX96` value and provides the flipped or unflipped
     * `sqrtPriceX96` value.
     *
     * @param _flipped If the PoolKey currencies are flipped
     * @param _initialPriceParams Parameters for the initial pricing
     *
     * @return sqrtPriceX96_ The `sqrtPriceX96` value
     */
    function getSqrtPriceX96(address /* _sender */, bool _flipped, bytes calldata _initialPriceParams) public view override returns (uint160 sqrtPriceX96_) {
        uint totalSupply;

        // This initial price contract needs to support the initial price parameters passing both the tokenSupply and
        // also excluding the tokenSupply. When decoding the data, if it doesn't exist, then it will revert so we will
        // need to try / catch.
        try this.decodeData(_initialPriceParams) returns (AnyMarketCappedPriceParams memory params) {
            // If we have a token supply override, then use it, otherwise use the total supply of the memecoin
            totalSupply = params.tokenSupply > 0 ? params.tokenSupply : IERC20(params.memecoin).totalSupply();
        } catch {
            // For our legacy approach, get the memecoin address and query the `totalSupply()` from the ERC20 directly
            (, address memecoin) = abi.decode(_initialPriceParams, (uint, address));
            totalSupply = IERC20(memecoin).totalSupply();
        }

        return _calculateSqrtPriceX96(getMarketCap(_initialPriceParams), totalSupply, !_flipped);
    }

    /**
     * Decodes the initial price parameters into the `AnyMarketCappedPriceParams` struct.
     *
     * @dev This allows for us to make the call in try / catch by exposing it externally.
     *
     * @param _data The initial price parameters
     *
     * @return The `AnyMarketCappedPriceParams` struct
     */
    function decodeData(bytes calldata _data) public pure returns (AnyMarketCappedPriceParams memory) {
        return abi.decode(_data, (AnyMarketCappedPriceParams));
    }

}