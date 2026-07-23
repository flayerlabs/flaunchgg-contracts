// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {IBidWall} from '@flaunch-interfaces/IBidWall.sol';
import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';
import {IInitialPrice} from '@flaunch-interfaces/IInitialPrice.sol';
import {IInternalSwapPool} from '@flaunch-interfaces/IInternalSwapPool.sol';
import {IOracle} from '@flaunch-interfaces/IOracle.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';
import {TreasuryActionManager} from '@flaunch/treasury/ActionManager.sol';

interface IAnyPositionManager {
    error AlreadyFlaunched();
    error CallerIsNotBidWall();
    error CannotBeInitializedDirectly();
    error UnknownPool(PoolId _poolId);
    error CallerIsNotApprovedCreator();

    event CreatorApproved(address _creator, bool _isApproved);
    event PoolCreated(
        PoolId indexed _poolId, address _memecoin, address _memecoinTreasury, uint _tokenId, bool _currencyFlipped, FlaunchParams _params
    );
    event PoolSwap(
        PoolId indexed poolId,
        int flAmount0,
        int flAmount1,
        int flFee0,
        int flFee1,
        int ispAmount0,
        int ispAmount1,
        int ispFee0,
        int ispFee1,
        int uniAmount0,
        int uniAmount1,
        int uniFee0,
        int uniFee1
    );
    event PoolStateUpdated(
        PoolId indexed _poolId, uint160 _sqrtPriceX96, int24 _tick, uint24 _protocolFee, uint24 _swapFee, uint128 _liquidity
    );
    event InitialPriceUpdated(address _initialPrice);

    struct ConstructorParams {
        address nativeToken;
        IPoolManager poolManager;
        FeeDistributor.FeeDistribution feeDistribution;
        IInitialPrice initialPrice;
        address protocolOwner;
        address protocolFeeRecipient;
        address flayGovernance;
        address feeEscrow;
        IFeeExemptions feeExemptions;
        TreasuryActionManager actionManager;
        IBidWall bidWall;
        IInternalSwapPool internalSwapPool;
        IOracle oracle;
    }

    struct FlaunchParams {
        address memecoin;
        address creator;
        uint24 creatorFeeAllocation;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }

    function flaunch(
        FlaunchParams calldata _params
    ) external;
    function poolKey(
        address _token
    ) external view returns (PoolKey memory);
    function getFlaunchingMarketCap(
        bytes calldata _initialPriceParams
    ) external view returns (uint);
}
