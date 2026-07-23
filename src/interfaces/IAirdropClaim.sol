// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAirdropClaim {
    // Allocate by merkle
    function allocate(
        address _token,
        bytes32 _merkle
    ) external payable;

    // Allocate to individual user
    function allocate(
        address _token,
        address _user,
        uint _amount
    ) external payable;

    // Allocate to multiple users
    function allocate(
        address _token,
        address[] calldata _user,
        uint[] calldata _amount
    ) external payable;

    // Approve or Unapprove a sender
    function setSender(
        address _sender,
        bool _approved
    ) external;
}
