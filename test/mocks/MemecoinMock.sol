// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Memecoin} from '@flaunch/Memecoin.sol';

contract MemecoinMock is Memecoin {
    function mint(
        address _to,
        uint _amount
    ) public override {
        _mint(_to, _amount);
    }
}
