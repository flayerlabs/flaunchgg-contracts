// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';


/**
 * Stores a registry of approves managers that have the functionality to override the default
 * fee calculator logic.
 */
contract CustomFeeManagerRegistry is Ownable {

    error ManagerAlreadyAdded(address _manager);
    error ManagerDoesNotExist(address _manager);
    error InvalidManager(address _manager);

    event ManagerAdded(address indexed _manager);
    event ManagerRemoved(address indexed _manager);

    /// Stores the list of approved managers that can be assigned to pools
    mapping (address _manager => bool _isApproved) public isApprovedManager;


    /**
     * Sets the owner of the contract.
     */
    constructor () {
        _initializeOwner(msg.sender);
    }

    /**
     * Adds a manager to the approved managers list.
     * 
     * @param _manager The address to add as an approved manager
     */
    function addManager(address _manager) external onlyOwner {
        // Ensure that the manager is not the zero address
        if (_manager == address(0)) {
            revert InvalidManager(_manager);
        }

        // Ensure that the manager is not already approved
        if (isApprovedManager[_manager]) {
            revert ManagerAlreadyAdded(_manager);
        }

        // Add the manager to the approved managers list
        isApprovedManager[_manager] = true;
        emit ManagerAdded(_manager);
    }

    /**
     * Removes a manager from the approved managers list.
     * 
     * @param _manager The address to remove from approved managers
     */
    function removeManager(address _manager) external onlyOwner {
        // Ensure that the manager exists and is already approved
        if (!isApprovedManager[_manager]) {
            revert ManagerDoesNotExist(_manager);
        }

        // Remove the manager from the approved managers list
        isApprovedManager[_manager] = false;
        emit ManagerRemoved(_manager);
    }

}