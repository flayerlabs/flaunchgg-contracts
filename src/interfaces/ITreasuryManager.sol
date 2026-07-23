// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeeEscrowRegistry} from '@flaunch-interfaces/IFeeEscrowRegistry.sol';
import {IManagerPermissions} from '@flaunch-interfaces/IManagerPermissions.sol';
import {Flaunch} from '@flaunch/Flaunch.sol';

/**
 * Acts as a middleware for revenue claims, allowing external protocols to build on top of Flaunch
 * and be able to have more granular control over the revenue yielded.
 */
interface ITreasuryManager {
    error AlreadyInitialized();
    error AlreadyDeposited();
    error FlaunchContractNotValid();
    error InvalidCreator();
    error NotInitialized();
    error NotManagerOwner();
    error TokenTimelocked(uint _unlockedAt);
    error UnknownFlaunchToken();
    error InvalidOwner();

    event ManagerOwnershipTransferred(address indexed _previousOwner, address indexed _newOwner);
    event PermissionsUpdated(address _permissions);
    event TreasuryEscrowed(address indexed _flaunch, uint indexed _tokenId, address _owner, address _sender);
    event TreasuryReclaimed(address indexed _flaunch, uint indexed _tokenId, address _sender, address _recipient);
    event TreasuryTimelocked(address indexed _flaunch, uint indexed _tokenId, uint _unlockedAt);

    /**
     * The Flaunch Token definition.
     *
     * @param flaunch The flaunch contract used to launch the token
     * @param tokenId The tokenId of the Flaunch ERC721
     */
    struct FlaunchToken {
        Flaunch flaunch;
        uint tokenId;
    }

    /**
     * Initializes the token by setting the contract ownership for the manager. It then processes
     * extended logic.
     *
     * @dev The {TreasuryManager} implementation will use an internal `_initialize` call for
     * their own logic.
     */
    function initialize(
        address _owner,
        bytes calldata _data
    ) external;

    /**
     * Transfers the ERC721 into the manager. It then processes extended logic.
     *
     * @dev The {TreasuryManager} implementation will use an internal `_deposit` call for
     * their own logic.
     */
    function deposit(
        FlaunchToken calldata _flaunchToken,
        address _creator,
        bytes calldata _data
    ) external;

    /**
     * Allows the ERC721 to be rescued from the manager by the owner of the contract.
     *
     * @dev This is designed as a last-resort call, rather than an expected flow.
     */
    function rescue(
        FlaunchToken calldata _flaunchToken,
        address _recipient
    ) external;

    /**
     * Returns the manager owner of the group.
     *
     * @return The manager owner of the group
     */
    function managerOwner() external view returns (address);

    /**
     * Checks if the specified address is a valid creator and can deposit tokens into the
     * treasury manager.
     *
     * @param _creator The address to check
     * @param _data Additional data to pass to the implementation
     *
     * @return `true` if the address is a valid creator, `false` otherwise
     */
    function isValidCreator(
        address _creator,
        bytes calldata _data
    ) external view returns (bool);

    /**
     * Returns the balance of the specified recipient.
     *
     * @param _recipient The recipient to check the balance of
     *
     * @return amount_ The balance of the specified recipient
     */
    function balances(
        address _recipient
    ) external view returns (uint amount_);

    /**
     * Claims the fees for the specified recipient.
     *
     * @return amount_ The amount of fees claimed
     */
    function claim() external returns (uint amount_);

    /*
     * Returns the permissions contract for the treasury manager.
     *
     * @return The permissions contract for the treasury manager
     */
    function permissions() external view returns (IManagerPermissions);

    /**
     * Sets the deposit permissions contract for the treasury manager.
     *
     * @dev Only the manager owner can call this function.
     *
     * @param _permissions The new deposit permissions contract
     */
    function setPermissions(
        address _permissions
    ) external;

    /**
     * Transfers ownership of the contract to a new account (`newOwner`).
     *
     * @dev Can only be called by the current owner.
     *
     * @param _newManagerOwner The new address that will become the owner
     */
    function transferManagerOwnership(
        address _newManagerOwner
    ) external;

    /**
     * Returns the fee escrow registry for the treasury manager.
     *
     * @return The fee escrow registry for the treasury manager
     */
    function feeEscrowRegistry() external view returns (IFeeEscrowRegistry);
}
