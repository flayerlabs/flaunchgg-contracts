// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';
import {ReentrancyGuard} from '@solady/utils/ReentrancyGuard.sol';

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {FullMath} from '@uniswap/v4-core/src/libraries/FullMath.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {ITrustedSignerFeeCalculator} from '@flaunch-interfaces/ITrustedSignerFeeCalculator.sol';
import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';

/**
 * A {IFeeCalculator} implementation that gates swaps during a token's fair launch phase behind
 * a signature issued by a trusted off-chain signer.
 *
 * When fair launch is enabled for a pool, each swap must carry a signed message that authorizes
 * the originating wallet to trade. The signer can either be a protocol-wide trusted signer or a
 * per-pool signer nominated by the pool creator. On top of the signature gate, the calculator
 * enforces optional per-transaction and per-wallet purchase caps to keep the launch fair.
 *
 * The fee itself is left untouched; this contract only validates access and tracks purchased
 * amounts, returning the base fee unchanged from {determineSwapFee}.
 */
contract TrustedSignerFeeCalculator is IFeeCalculator, ITrustedSignerFeeCalculator, Ownable, ReentrancyGuard, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// The set of protocol-wide signers that can authorize swaps for any gated pool
    EnumerableSet.AddressSet internal _trustedSigners;

    /// Tracks how many tokens a wallet has purchased per pool, used to enforce the wallet cap
    mapping(PoolId _poolId => mapping(address _wallet => uint _amount)) public walletPurchasedAmount;

    /// Stores an optional per-pool signer that overrides the protocol-wide trusted signers
    mapping(PoolId _poolId => TrustedPoolKeySigner _signer) public trustedPoolKeySigner;

    /// Stores the fair launch configuration (enabled flag and caps) for each pool
    mapping(PoolId _poolId => FairLaunchSettings _settings) public fairLaunchSettings;

    /// Tracks consumed signatures to prevent the same authorization being replayed
    mapping(bytes32 _signature => bool _used) internal _usedSignatures;

    /// The native token used by the protocol, set once at deployment
    address public immutable nativeToken;

    /**
     * Sets the native token and grants the deployer admin control over the contract.
     *
     * @param _nativeToken The address of the protocol's native token
     */
    constructor(
        address _nativeToken
    ) {
        // Store the native token used to identify the non-memecoin side of a pool
        nativeToken = _nativeToken;

        // Grant the deployer the admin role and contract ownership
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _initializeOwner(msg.sender);
    }

    /**
     * Returns the swap fee for a pool. This calculator does not modify the fee, so the base fee
     * is always returned unchanged.
     *
     * @param _baseFee The base fee passed in by the {PositionManager}
     *
     * @return swapFee_ The unmodified base fee
     */
    function determineSwapFee(
        PoolKey memory,
        SwapParams memory,
        uint24 _baseFee
    ) public pure returns (uint24 swapFee_) {
        // We never alter the fee; just echo back the base fee
        return _baseFee;
    }

    /**
     * Configures the fair launch settings for a pool. Only callable by the {PositionManager} as
     * part of the flaunch flow.
     *
     * @param _poolId The ID of the pool being configured
     * @param _params ABI-encoded `(bool enabled, uint walletCap, uint txCap)`, or empty to disable
     */
    function setFlaunchParams(
        PoolId _poolId,
        bytes calldata _params
    ) external override {
        // Only the PositionManager is permitted to set fair launch parameters
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) {
            revert CallerNotPositionManager();
        }

        // Default to a disabled configuration with no caps
        bool enabled;
        uint walletCap;
        uint txCap;

        // Decode the provided settings only if any params were supplied
        if (_params.length != 0) {
            (enabled, walletCap, txCap) = abi.decode(_params, (bool, uint, uint));
        }

        // Store the resolved fair launch settings against the pool
        fairLaunchSettings[_poolId] = FairLaunchSettings({enabled: enabled, walletCap: walletCap, txCap: txCap});

        // Notify listeners of the updated configuration
        emit PoolKeyAccessUpdated(_poolId, fairLaunchSettings[_poolId]);
    }

    /**
     * Validates a swap against the pool's fair launch rules. Called by the {PositionManager} after
     * a swap, this enforces signature authorization, replay protection and the configured caps.
     *
     * @dev Authority comes from the signed message: the authorized buyer is an explicit, signed
     * field and the signature can never be spoofed by a lying router. On top of that, `tx.origin`
     * is required to equal the signed buyer as an anti-front-running binding, so a copied signed
     * message cannot be submitted by anyone other than the buyer it was issued to. The swap's
     * `_sender` (the router/caller) is still ignored.
     *
     * @dev Intentional trade-off: fair-launch buyers must submit the swap from the signed EOA, so
     * smart-contract wallets and account-abstraction flows (where `tx.origin` is a bundler/relayer
     * rather than the buyer) are not supported during the gated window.
     *
     * @param _poolKey The key for the pool being swapped against
     * @param _params The swap parameters, used to estimate the tokens received
     * @param _hookData Arbitrary swap data carrying the signed authorization message
     */
    function trackSwap(
        address,
        PoolKey calldata _poolKey,
        SwapParams calldata _params,
        BalanceDelta,
        bytes calldata _hookData
    ) public nonReentrant {
        // Only the PositionManager is permitted to report swaps
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) {
            revert CallerNotPositionManager();
        }

        // If fair launch is not enabled for this pool, there is nothing to enforce
        PoolId poolId = _poolKey.toId();
        FairLaunchSettings memory settings = fairLaunchSettings[poolId];
        if (!settings.enabled) {
            return;
        }

        // If the creator opted into a per-pool signer but left it unset, skip enforcement
        TrustedPoolKeySigner memory poolSigner = trustedPoolKeySigner[poolId];
        if (poolSigner.enabled && poolSigner.signer == address(0)) {
            return;
        }

        // Validate the signed message the swap carries and recover the authorized buyer from it.
        // The buyer is an explicit, signed field, so authority is derived solely from the
        // signature and can never be spoofed by a lying router or a reused `tx.origin`.
        (address buyer, bytes32 messageHash, bytes memory signature) = _validateSignature(poolId, _hookData);

        // Bind the authorization to the transaction originator. The signed message is public
        // calldata, so requiring `tx.origin` to equal the signed buyer stops a front-runner from
        // copying a victim's message to receive the tokens, consume the victim's cap and burn the
        // signature. This check runs before any accounting or signature consumption below, so a
        // mismatched submitter can neither spend the cap nor invalidate the buyer's own swap.
        if (buyer != tx.origin) {
            revert BuyerNotTransactionOrigin(buyer, tx.origin);
        }

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();

        // Reject signatures that have already been used to prevent replays
        if (_usedSignatures[ethSignedMessageHash]) {
            revert SignatureAlreadyUsed();
        }

        // Recover the signer from the signature and check it against the expected authority
        (address recoveredSigner,,) = ethSignedMessageHash.tryRecover(signature);
        if (poolSigner.enabled) {
            // A per-pool signer must match exactly
            if (recoveredSigner != poolSigner.signer) {
                revert InvalidSigner(recoveredSigner);
            }
        } else if (!isTrustedSigner(recoveredSigner)) {
            // Otherwise fall back to the protocol-wide trusted signer set
            revert InvalidSigner(recoveredSigner);
        }

        // Estimate the tokens received and ensure the purchase stays within any configured cap
        uint transactionAmount = _estimateReceivedTokens(_poolKey, _params.amountSpecified);
        (bool hasCap, uint maxTokensOut_) = maxTokensOut(poolId, buyer);
        if (hasCap && transactionAmount > maxTokensOut_) {
            revert TransactionCapExceeded(transactionAmount, maxTokensOut_);
        }

        // Record the purchase against the signed buyer and mark the signature as consumed
        walletPurchasedAmount[poolId][buyer] += transactionAmount;
        _usedSignatures[ethSignedMessageHash] = true;
    }

    /**
     * Adds a protocol-wide trusted signer that can authorize swaps for any gated pool.
     *
     * @param _signer The address of the signer to trust
     */
    function addTrustedSigner(
        address _signer
    ) external onlyOwner {
        // The zero address can never be a valid signer
        if (_signer == address(0)) {
            revert InvalidSigner(_signer);
        }

        // Add the signer, reverting if it was already present
        if (!_trustedSigners.add(_signer)) {
            revert SignerAlreadyAdded(_signer);
        }

        // Notify listeners that the signer is now trusted
        emit TrustedSignerUpdated(_signer, true);
    }

    /**
     * Removes a protocol-wide trusted signer.
     *
     * @param _signer The address of the signer to remove
     */
    function removeTrustedSigner(
        address _signer
    ) external onlyOwner {
        // Remove the signer, reverting if it was not present
        if (!_trustedSigners.remove(_signer)) {
            revert SignerDoesNotExist(_signer);
        }

        // Notify listeners that the signer is no longer trusted
        emit TrustedSignerUpdated(_signer, false);
    }

    /**
     * Allows a pool creator to nominate a dedicated signer for their own pool, overriding the
     * protocol-wide trusted signers for that pool.
     *
     * @param _poolKey The key for the pool being configured
     * @param _signer The address that will authorize swaps for this pool
     */
    function setTrustedPoolKeySigner(
        PoolKey calldata _poolKey,
        address _signer
    ) external nonReentrant {
        // Only the creator of the pool's memecoin may set the per-pool signer
        (address memecoin,) = _discoverMemecoin(_poolKey);
        if (IMemecoin(memecoin).creator() != msg.sender) {
            revert NotPoolCreator();
        }

        // Store the per-pool signer and flag it as enabled
        PoolId poolId = _poolKey.toId();
        trustedPoolKeySigner[poolId] = TrustedPoolKeySigner({signer: _signer, enabled: true});

        // Notify listeners of the new per-pool signer
        emit PoolKeySignerUpdated(poolId, _signer);
    }

    /**
     * Checks whether an address is a protocol-wide trusted signer.
     *
     * @param _signer The address to check
     *
     * @return valid_ True if the address is a trusted signer
     */
    function isTrustedSigner(
        address _signer
    ) public view returns (bool valid_) {
        valid_ = _trustedSigners.contains(_signer);
    }

    /**
     * Calculates the maximum number of tokens a wallet may still purchase for a pool, taking into
     * account both the per-transaction cap and the wallet's remaining allowance under the wallet
     * cap.
     *
     * @param _poolId The ID of the pool
     * @param _origin The wallet whose remaining allowance is being checked
     *
     * @return hasCap_ True if any cap (transaction or wallet) applies to the pool
     * @return maxTokensOut_ The maximum tokens the wallet may receive in this transaction
     */
    function maxTokensOut(
        PoolId _poolId,
        address _origin
    ) public view returns (bool hasCap_, uint maxTokensOut_) {
        // Start from the per-transaction cap and flag whether any cap is configured
        FairLaunchSettings memory settings = fairLaunchSettings[_poolId];
        maxTokensOut_ = settings.txCap;
        hasCap_ = settings.walletCap != 0 || settings.txCap != 0;

        // When a wallet cap exists, clamp the result to the wallet's remaining allowance
        if (settings.walletCap != 0) {
            uint remainingWalletAmount = settings.walletCap - walletPurchasedAmount[_poolId][_origin];

            // Use the wallet allowance when there is no tx cap, or when it is the tighter limit
            if (maxTokensOut_ == 0 || remainingWalletAmount < maxTokensOut_) {
                maxTokensOut_ = remainingWalletAmount;
            }
        }
    }

    /**
     * Resolves the memecoin address from a pool key by identifying which side is the native token,
     * and reports whether the currencies are flipped.
     *
     * @param _poolKey The key for the pool
     *
     * @return memecoin_ The address of the memecoin in the pool
     * @return isFlipped_ True if the memecoin is currency0 (native token is currency1)
     */
    function _discoverMemecoin(
        PoolKey calldata _poolKey
    ) internal view returns (address memecoin_, bool isFlipped_) {
        // The memecoin is whichever currency is not the native token
        if (nativeToken == Currency.unwrap(_poolKey.currency0)) {
            memecoin_ = Currency.unwrap(_poolKey.currency1);
        } else if (nativeToken == Currency.unwrap(_poolKey.currency1)) {
            memecoin_ = Currency.unwrap(_poolKey.currency0);
            isFlipped_ = true;
        }

        // The pool key is invalid if neither side is the native token
        if (memecoin_ == address(0)) {
            revert InvalidPoolKey();
        }
    }

    /**
     * Estimates the number of memecoin tokens received from a swap, used for cap enforcement.
     *
     * @param _poolKey The key for the pool
     * @param _amountSpecified The swap amount; positive for exact-output, negative for exact-input
     *
     * @return tokensOut_ The estimated number of tokens received
     */
    function _estimateReceivedTokens(
        PoolKey memory _poolKey,
        int _amountSpecified
    ) internal view returns (uint tokensOut_) {
        // A zero amount swap yields no tokens
        if (_amountSpecified == 0) {
            return 0;
        }

        // A positive amount is already the exact token output requested
        if (_amountSpecified > 0) {
            return uint(_amountSpecified);
        }

        // For an exact-input swap, quote the output using the pool's initial launch tick
        PoolId poolId = _poolKey.toId();
        bool nativeIsZero = nativeToken == Currency.unwrap(_poolKey.currency0);

        // Get the initial pool tick from the PositionManager
        int24 launchTick = IPositionManager(address(_poolKey.hooks)).initialPoolTick(poolId);

        // Convert the spent native amount into an expected memecoin amount at the launch price
        return _getQuoteAtTick(
            launchTick,
            uint(-_amountSpecified),
            Currency.unwrap(nativeIsZero ? _poolKey.currency0 : _poolKey.currency1),
            Currency.unwrap(nativeIsZero ? _poolKey.currency1 : _poolKey.currency0)
        );
    }

    /**
     * Calculates the amount of quote token equivalent to a base token amount at a given tick.
     *
     * @dev Mirrors the Uniswap V3 OracleLibrary quote, branching on the size of the price to avoid
     * overflow when squaring the sqrt price.
     *
     * @param _tick The tick to price the quote at
     * @param _baseAmount The amount of base token to convert
     * @param _baseToken The address of the base token
     * @param _quoteToken The address of the quote token
     *
     * @return quoteAmount_ The equivalent amount denominated in the quote token
     */
    function _getQuoteAtTick(
        int24 _tick,
        uint _baseAmount,
        address _baseToken,
        address _quoteToken
    ) internal pure returns (uint quoteAmount_) {
        // Convert the tick into a sqrt price
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);

        // For smaller prices the squared ratio fits in 192 bits without overflowing
        if (sqrtPriceX96 <= type(uint128).max) {
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            // Apply or invert the ratio depending on token ordering
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX192, _baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, _baseAmount, ratioX192);
        } else {
            // For larger prices, scale down to a 128-bit ratio to avoid overflow
            uint ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            // Apply or invert the ratio depending on token ordering
            quoteAmount_ = _baseToken < _quoteToken
                ? FullMath.mulDiv(ratioX128, _baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, _baseAmount, ratioX128);
        }
    }

    /**
     * Decodes and validates the signed authorization message carried in the swap's hook data,
     * checking the deadline and target pool before returning the authorized buyer along with the
     * data needed to recover the signer.
     *
     * @dev The authorized buyer is an explicit field inside the signed struct, so authority is
     * recovered solely from the signature. The buyer is never inferred from `tx.origin` or a
     * router-reported `msgSender()`, which prevents a lying router (or a front-runner replaying a
     * victim's plaintext hook data) from consuming another wallet's authorization or fair-launch cap.
     *
     * @param _poolId The ID of the pool being swapped against
     * @param _hookData The hook data containing the encoded {SignedMessage}
     *
     * @return buyer_ The authorized buyer the signature commits to
     * @return messageHash_ The hash that the signature is expected to have signed
     * @return signature_ The signature bytes to recover the signer from
     */
    function _validateSignature(
        PoolId _poolId,
        bytes calldata _hookData
    ) internal view returns (address buyer_, bytes32 messageHash_, bytes memory signature_) {
        // Extract the signed message from the hook data
        (, SignedMessage memory signedMessage) = abi.decode(_hookData, (address, SignedMessage));

        // Reject the authorization if it has expired
        if (block.timestamp > signedMessage.deadline) {
            revert DeadlineExpired(signedMessage.deadline);
        }

        // Ensure the message was signed for the pool actually being swapped
        bytes32 swapPoolId = PoolId.unwrap(_poolId);
        if (signedMessage.poolId != swapPoolId) {
            revert InvalidPoolKey();
        }

        // Reconstruct the signed hash from the buyer, pool and deadline, and return the signature.
        // Binding the buyer into the hash is what ties the authorization to a specific wallet.
        buyer_ = signedMessage.buyer;
        messageHash_ = keccak256(abi.encodePacked(signedMessage.buyer, signedMessage.poolId, signedMessage.deadline));
        signature_ = signedMessage.signature;
    }
}
