// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';

contract PoolManagerMock {
    function take(
        Currency,
        /* currency */
        address,
        /* to */
        uint /* amount */
    ) external {
        // ..
    }
}
