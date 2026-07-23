// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface ITrustedSignerFeeCalculator {
    error BuyerNotTransactionOrigin(address _buyer, address _txOrigin);
    error CallerNotPositionManager();
    error DeadlineExpired(uint _deadline);
    error InvalidPoolKey();
    error InvalidSigner(address _invalidSigner);
    error NotPoolCreator();
    error SignatureAlreadyUsed();
    error SignerAlreadyAdded(address _signer);
    error SignerDoesNotExist(address _signer);
    error TransactionCapExceeded(uint _requestedAmount, uint _maxTokensOut);

    event PoolKeySignerUpdated(PoolId _poolId, address indexed _signer);
    event PoolKeyAccessUpdated(PoolId _poolId, FairLaunchSettings _settings);
    event TrustedSignerUpdated(address indexed _signer, bool _isTrusted);

    struct SignedMessage {
        address buyer;
        bytes32 poolId;
        uint deadline;
        bytes signature;
    }

    struct PremineSignedMessage {
        uint deadline;
        bytes signature;
    }

    struct TrustedPoolKeySigner {
        address signer;
        bool enabled;
    }

    struct FairLaunchSettings {
        bool enabled;
        uint walletCap;
        uint txCap;
    }

    function walletPurchasedAmount(
        PoolId _poolId,
        address _wallet
    ) external view returns (uint _amount);
    function trustedPoolKeySigner(
        PoolId _poolId
    ) external view returns (address signer, bool enabled);
    function fairLaunchSettings(
        PoolId _poolId
    ) external view returns (bool enabled, uint walletCap, uint txCap);
    function nativeToken() external view returns (address);
    function addTrustedSigner(
        address _signer
    ) external;
    function removeTrustedSigner(
        address _signer
    ) external;
    function setTrustedPoolKeySigner(
        PoolKey calldata _poolKey,
        address _signer
    ) external;
    function isTrustedSigner(
        address _signer
    ) external view returns (bool valid_);
    function maxTokensOut(
        PoolId _poolId,
        address _origin
    ) external view returns (bool hasCap_, uint maxTokensOut_);
}
