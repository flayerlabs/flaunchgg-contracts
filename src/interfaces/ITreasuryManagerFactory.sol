// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITreasuryManagerFactory {
    error UnknownManagerImplemention();

    event ManagerImplementationApproved(address indexed _managerImplementation);
    event ManagerDeployed(address indexed _manager, address indexed _managerImplementation);
    event ManagerImplementationUnapproved(address indexed _managerImplementation);

    function approvedManagerImplementation(
        address _managerImplementation
    ) external view returns (bool _approved);

    function managerImplementation(
        address _manager
    ) external view returns (address _managerImplementation);

    function deployAndInitializeManager(
        address _managerImplementation,
        address _owner,
        bytes calldata _data
    ) external returns (address payable manager_);

    function approveManager(
        address _managerImplementation
    ) external;

    function unapproveManager(
        address _managerImplementation
    ) external;
}
