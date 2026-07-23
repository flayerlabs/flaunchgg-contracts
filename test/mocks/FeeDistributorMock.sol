// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';

/**
 * Exposes the {FeeDistributor} internals that are tested in isolation, without inheriting the
 * full {PositionManager}.
 *
 * The position managers are Uniswap V4 hooks and sit close to the EIP-170 limit, so any helper
 * that only needs {FeeDistributor} state is hosted here rather than adding bytecode to
 * {PositionManagerMock} (which has to deploy to a permission-encoded hook address).
 */
contract FeeDistributorMock is FeeDistributor {
    constructor(
        address _nativeToken,
        FeeDistribution memory _feeDistribution,
        address _protocolOwner,
        address _flayGovernance,
        address _feeEscrow
    ) FeeDistributor(_nativeToken, _feeDistribution, _protocolOwner, _flayGovernance, _feeEscrow) {
        // ..
    }

    function captureSwapFees(
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata _params,
        Currency swapFeeCurrency,
        uint swapAmount,
        IFeeExemptions.FeeExemption calldata swapFeeOverride
    ) external returns (uint swapFee_) {
        return _captureSwapFees(poolManager, key, _params, IFeeCalculator(address(0)), swapFeeCurrency, swapAmount, swapFeeOverride);
    }

    function allocateFeesMock(
        PoolId _poolId,
        address _recipient,
        uint _amount
    ) external {
        _allocateFees(_poolId, _recipient, _amount);
    }

    /**
     * The BidWall is owned by the {PositionManager}, so there is nothing to unwind here.
     */
    function _closeBidWall(
        PoolKey memory
    ) internal override {
        // ..
    }
}
