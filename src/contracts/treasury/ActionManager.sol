// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {ITreasuryActionManager} from '@flaunch-interfaces/ITreasuryActionManager.sol';

/**
 * Allows the contract owner to manage approved {ITreasuryAction} contracts.
 */
contract TreasuryActionManager is ITreasuryActionManager, Ownable {
    // Mapping to store approved action contract addresses
    mapping(address _action => bool _approved) public approvedActions;

    /**
     * Sets the contract owner.
     *
     * @dev This contract should be created in the {PositionManager} constructor call.
     */
    constructor(
        address _protocolOwner
    ) {
        _initializeOwner(_protocolOwner);
    }

    /**
     * Approves an action contract.
     *
     * @param _action {ITreasuryAction} contract address
     */
    function approveAction(
        address _action
    ) external onlyOwner {
        approvedActions[_action] = true;
        emit ActionApproved(_action);
    }

    /**
     * Remove an action contract from approval.
     *
     * @param _action {ITreasuryAction} contract address
     */
    function unapproveAction(
        address _action
    ) external onlyOwner {
        approvedActions[_action] = false;
        emit ActionUnapproved(_action);
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}
