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
import {ITreasuryActionManager} from '@flaunch-interfaces/ITreasuryActionManager.sol';
import {FeeDistributor} from '@flaunch/hooks/FeeDistributor.sol';

interface IPositionManager {
    error CallerIsNotBidWall();
    error CannotBeInitializedDirectly();
    error InsufficientFlaunchFee(uint _paid, uint _required);
    error InsufficientPreminePayment(uint _paid, uint _required);
    error PremineExceedsInitialAmount(uint _buyAmount, uint _initialSupply);
    error TokenNotFlaunched(uint _flaunchesAt);
    error UnknownMemecoin(address _memecoin);
    error UnknownPool(PoolId _poolId);

    event PoolCreated(
        PoolId indexed _poolId,
        address _memecoin,
        address _memecoinTreasury,
        uint _tokenId,
        bool _currencyFlipped,
        uint _flaunchFee,
        FlaunchParams _params
    );
    event PoolScheduled(PoolId indexed _poolId, uint _flaunchesAt);
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
    event PoolPremine(PoolId indexed _poolId, address _recipient, uint _tokensReceived, uint _ethSpent);

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
        ITreasuryActionManager actionManager;
        IBidWall bidWall;
        IInternalSwapPool internalSwapPool;
        IOracle oracle;
    }

    struct FlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint premineAmount;
        address creator;
        uint24 creatorFeeAllocation;
        uint flaunchAt;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }

    function flaunch(
        FlaunchParams calldata _params
    ) external payable returns (address memecoin_);

    function poolKey(
        address _token
    ) external view returns (PoolKey memory);

    function getFlaunchingFee(
        bytes calldata _initialPriceParams
    ) external view returns (uint);

    function getFlaunchingMarketCap(
        bytes calldata _initialPriceParams
    ) external view returns (uint);

    function initialPoolTick(
        PoolId _poolId
    ) external view returns (int24);
}
