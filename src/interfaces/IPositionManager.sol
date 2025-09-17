// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';
import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';


interface IPositionManager {
    function fairLaunch() external view returns (FairLaunch);
    function getFeeCalculator(bool _isFairLaunch) external view returns (IFeeCalculator);
}