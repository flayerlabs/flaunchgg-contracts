// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchFeeExemption} from '@flaunch/price/FlaunchFeeExemption.sol';

interface IInitialPrice {
    function flaunchFeeExemption() external returns (FlaunchFeeExemption);

    function getFlaunchingFee(
        address _sender,
        bytes calldata _initialPriceParams
    ) external view returns (uint);

    function getMarketCap(
        bytes calldata _initialPriceParams
    ) external view returns (uint);

    function getSqrtPriceX96(
        address _sender,
        bool _flipped,
        bytes calldata _initialPriceParams
    ) external view returns (uint160);
}
