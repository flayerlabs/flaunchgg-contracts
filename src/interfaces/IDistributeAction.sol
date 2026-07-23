// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITreasuryAction} from '@flaunch-interfaces/ITreasuryAction.sol';

interface IDistributeAction is ITreasuryAction {
    struct Distribution {
        address recipient;
        bool token0;
        uint amount;
    }
}
