// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Holds definitions for known `AccessControl` roles.
 */
library ProtocolRoles {
    bytes32 public constant FLAUNCH = keccak256('Flaunch');
    bytes32 public constant NOTIFIER = keccak256('Notifier');
    bytes32 public constant POSITION_MANAGER = keccak256('PositionManager');
}
