// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITreasuryActionManager {
    event ActionApproved(address indexed _action);
    event ActionUnapproved(address indexed _action);

    function approvedActions(
        address _action
    ) external view returns (bool _approved);
    function approveAction(
        address _action
    ) external;
    function unapproveAction(
        address _action
    ) external;
}
