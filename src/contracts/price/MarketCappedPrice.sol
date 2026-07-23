// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';
import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';

import {IInitialPrice} from '@flaunch-interfaces/IInitialPrice.sol';

/**
 * This contract defines an initial flaunch price by finding the ETH equivalent price of
 * a USDC value. This is done by checking the an ETH:USDC pool to find an ETH price of an
 * Owner defined USDC price.
 *
 * This ETH equivalent price is then cast against the memecoin supply to determine market
 * cap.
 */
contract MarketCappedPrice is IInitialPrice, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MarketCapTooSmall(uint _usdcMarketCap, uint _usdcMarketCapMinimum);

    event FlaunchFeeThresholdUpdated(uint _flaunchFeeThreshold);

    /**
     * The struct of data that should be passed from the flaunching flow to define the
     * desired market cap when a token is flaunching.
     *
     * @member usdcMarketCap The USDC price of the token market cap
     */
    struct MarketCappedPriceParams {
        uint usdcMarketCap;
    }

    /// Sets a minimum market cap threshold
    uint public constant MINIMUM_USDC_MARKET_CAP = 1e6;

    /// The Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// The token addresses for ETH and USDC
    Currency public immutable ethToken;
    Currency public immutable usdcToken;

    /// The Uniswap V4 PoolId that holds our ETH : USDC position
    PoolId public poolId;
    bool public usdcToken0;

    /// The minimum flaunch price that would incur a flaunching fee
    uint public flaunchFeeThreshold;

    /// The {FlaunchFeeExemption} contract
    FlaunchFeeExemption public immutable flaunchFeeExemption;

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
    ) {
        // Map our PoolManager
        poolManager = IPoolManager(_poolManager);

        // Set our tokens
        ethToken = Currency.wrap(_ethToken);
        usdcToken = Currency.wrap(_usdcToken);

        // Register our {FlaunchFeeExemption}
        flaunchFeeExemption = FlaunchFeeExemption(_flaunchFeeExemption);

        // Grant ownership permissions to the caller
        _initializeOwner(_protocolOwner);
    }

    /**
     * Sets a Flaunching fee of 0.1% of the desired market cap.
     *
     * @param _sender The address flaunching, which may be excluded from flaunching fees
     * @param _initialPriceParams Parameters for the initial pricing
     *
     * @return uint The fee taken from the user for Flaunching a token
     */
    function getFlaunchingFee(
        address _sender,
        bytes calldata _initialPriceParams
    ) public view returns (uint) {
        // Decode our initial price parameters to give the USDC value requested
        (MarketCappedPriceParams memory params) = abi.decode(_initialPriceParams, (MarketCappedPriceParams));

        // If the fee is below our set threshold, then we want to exclude the fee
        if (params.usdcMarketCap <= flaunchFeeThreshold) {
            return 0;
        }

        // Check if our `_sender` is fee excluded
        if (flaunchFeeExemption.feeExcluded(_sender)) {
            return 0;
        }

        return getMarketCap(_initialPriceParams) / 1000;
    }

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
    ) public view virtual returns (uint160 sqrtPriceX96_) {
        return _calculateSqrtPriceX96(getMarketCap(_initialPriceParams), TokenSupply.INITIAL_SUPPLY, !_flipped);
    }

    /**
     * Updates the pool that we read the price market cap from.
     *
     * @dev This can only be called by the contract owner
     *
     * @param _poolKey The new Uniswap V4 PoolKey
     */
    function setPool(
        PoolKey calldata _poolKey
    ) public onlyOwner {
        // Ensure the token pair is ETH : USDC
        require(
            (_poolKey.currency0 == usdcToken && _poolKey.currency1 == ethToken)
                || (_poolKey.currency1 == usdcToken && _poolKey.currency0 == ethToken),
            'Invalid token pair'
        );

        poolId = _poolKey.toId();
        usdcToken0 = _poolKey.currency0 == usdcToken;
    }

    /**
     * Gets the ETH value of the desired USDC market cap.
     *
     * @param _initialPriceParams Parameters for the initial pricing
     *
     * @return uint The ETH value of the market cap
     */
    function getMarketCap(
        bytes calldata _initialPriceParams
    ) public view returns (uint) {
        // Decode our initial price parameters to give the USDC value requested
        (MarketCappedPriceParams memory params) = abi.decode(_initialPriceParams, (MarketCappedPriceParams));

        // Ensure that our requested market cap is sufficient
        if (params.usdcMarketCap < MINIMUM_USDC_MARKET_CAP) {
            revert MarketCapTooSmall(params.usdcMarketCap, MINIMUM_USDC_MARKET_CAP);
        }

        // Current sqrtPriceX96 of ETH:USDC
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // This is the price of ETH in USDC terms
        uint priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint ethUSDCPrice = (usdcToken0) ? FullMath.mulDiv(1e18, 1 << 96, priceX96) : FullMath.mulDiv(1e18, priceX96, 1 << 96);

        return FullMath.mulDiv(params.usdcMarketCap, 1e18, ethUSDCPrice);
    }

    /**
     * Allows the `flaunchFeeThreshold` to be updated.
     *
     * @param _flaunchFeeThreshold The new flaunch fee threshold
     */
    function setFlaunchFeeThreshold(
        uint _flaunchFeeThreshold
    ) public onlyOwner {
        flaunchFeeThreshold = _flaunchFeeThreshold;
        emit FlaunchFeeThresholdUpdated(_flaunchFeeThreshold);
    }

    /**
     * Calculates a sqrtPriceX96 based on token0 and token1 amounts, as well as a boolean that
     * shows if the token positions will be flipped.
     *
     * @param _ethAmount The amount of ETH for the pool
     * @param _tokenAmount The number of tokens for the pool
     * @param _isEthToken0 If ETH will be token0
     *
     * @return sqrtPriceX96_ The calculated sqrtPriceX96 value
     */
    function _calculateSqrtPriceX96(
        uint _ethAmount,
        uint _tokenAmount,
        bool _isEthToken0
    ) internal pure returns (uint160 sqrtPriceX96_) {
        require(_ethAmount > 0 && _tokenAmount > 0, 'Amounts must be greater than zero');

        // Calculate the price ratio depending on token order
        if (_isEthToken0) {
            // ETH is token0, TOKEN is token1
            return uint160(_sqrt(FullMath.mulDiv(_tokenAmount, 1 << 192, _ethAmount)));
        }

        // TOKEN is token0, ETH is token1
        return uint160(_sqrt(FullMath.mulDiv(_ethAmount, 1 << 192, _tokenAmount)));
    }

    /**
     * Helper function for square root.
     */
    function _sqrt(
        uint _x
    ) internal pure returns (uint result_) {
        if (_x == 0) {
            return 0;
        }
        uint z = (_x + 1) / 2;
        result_ = _x;
        while (z < result_) {
            result_ = z;
            z = (_x / z + z) / 2;
        }
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure virtual override returns (bool) {
        return true;
    }
}
