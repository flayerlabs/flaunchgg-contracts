// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IManagerPermissions {
    function isValidCreator(
        address _creator,
        bytes calldata _data
    ) external view returns (bool);
}
