// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface IDeployAutoLPAction {
    /**
     * Compounds accrued LP fees for the AutoLP position bound to the supplied AutoLP {PoolKey}.
     * Public + permissionless: the AutoLP hook calls this from `afterSwap`, and anyone may
     * trigger it externally to realize accrued fees. Native-side fees are forwarded to the
     * memecoin treasury, memecoin-side fees are re-deposited back into the position.
     *
     * @param _autoLPPoolKey The AutoLP {PoolKey} (i.e. the one returned by `AutoLP.getLPPoolKey`)
     */
    function compoundFees(
        PoolKey memory _autoLPPoolKey
    ) external;
}
