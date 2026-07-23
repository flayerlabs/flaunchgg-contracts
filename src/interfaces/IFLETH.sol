// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFLETH {
    function deposit(
        uint _amount
    ) external payable;

    function withdraw(
        uint _amount
    ) external;

    function allowance(
        address _owner,
        address _spender
    ) external returns (uint);

    function approve(
        address _spender,
        uint _amount
    ) external returns (bool);

    function balanceOf(
        address _owner
    ) external returns (uint);

    function transfer(
        address _recipient,
        uint _amount
    ) external returns (bool);

    function transferFrom(
        address _spender,
        address _recipient,
        uint _amount
    ) external returns (bool);
}
