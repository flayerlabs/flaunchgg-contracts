// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibClone} from '@solady/utils/LibClone.sol';

import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';

/**
 * Minimal, permissionless {ITreasuryManagerFactory} implementation for testing. Mirrors the clone
 * + initialize flow of the real factory (which lives in the flaunch-managers repo) without any
 * access control or fee escrow wiring.
 */
contract TreasuryManagerFactoryMock is ITreasuryManagerFactory {
    /// Approved manager implementation addresses
    mapping(address _managerImplementation => bool _approved) public approvedManagerImplementation;

    /// Mapping of deployments to their implementations
    mapping(address _manager => address _managerImplementation) public managerImplementation;

    function deployManager(
        address _managerImplementation
    ) public returns (address payable manager_) {
        if (!approvedManagerImplementation[_managerImplementation]) {
            revert UnknownManagerImplemention();
        }

        manager_ = payable(LibClone.clone(_managerImplementation));
        managerImplementation[manager_] = _managerImplementation;
        emit ManagerDeployed(manager_, _managerImplementation);
    }

    function deployAndInitializeManager(
        address _managerImplementation,
        address _owner,
        bytes calldata _data
    ) public returns (address payable manager_) {
        manager_ = deployManager(_managerImplementation);
        ITreasuryManager(manager_).initialize(_owner, _data);
    }

    function approveManager(
        address _managerImplementation
    ) public {
        approvedManagerImplementation[_managerImplementation] = true;
        emit ManagerImplementationApproved(_managerImplementation);
    }

    function unapproveManager(
        address _managerImplementation
    ) public {
        approvedManagerImplementation[_managerImplementation] = false;
        emit ManagerImplementationUnapproved(_managerImplementation);
    }
}
