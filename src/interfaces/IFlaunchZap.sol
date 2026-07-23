// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

interface IFlaunchZap {
    error CreatorCannotBeZero();

    /**
     * Thrown when `deployAndInitializeManager` is called on a zap that was deployed without a
     * {ITreasuryManagerFactory} bound (`address(0)`).
     */
    error TreasuryManagerFactoryNotSet();

    /**
     * If the manager is an approved implementation, then its instance will be deployed. Otherwise
     * the flaunch token will be transferred directly to the manager.
     */
    struct TreasuryManagerParams {
        address manager;
        address permissions;
        bytes initializeData;
        bytes depositData;
    }

    function flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner
    ) external payable returns (address memecoin_, uint ethSpent_);

    function flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        TreasuryManagerParams calldata _treasuryManagerParams,
        address _trustedFeeSigner
    ) external payable returns (address memecoin_, uint ethSpent_, address deployedManager_);

    function deployAndInitializeManager(
        address _managerImplementation,
        address _owner,
        bytes calldata _data,
        address _permissions
    ) external returns (address payable manager_);

    function calculateFee(
        IPositionManager.FlaunchParams memory _flaunchParams,
        uint _slippage
    ) external view returns (uint ethRequired_);
}
