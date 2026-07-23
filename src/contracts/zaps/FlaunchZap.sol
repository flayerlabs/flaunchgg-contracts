// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';

import {IFlaunchZap} from '@flaunch-interfaces/IFlaunchZap.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';
import {ITrustedSignerFeeCalculator} from '@flaunch-interfaces/ITrustedSignerFeeCalculator.sol';

/**
 * Single-transaction entrypoint for flaunching a memecoin with optional extras that the
 * {PositionManager} alone cannot provide: registering a trusted fee signer against the new pool
 * and escrowing the Flaunch ERC721 into a treasury manager.
 *
 * The zap holds no funds between transactions: any ETH or memecoin it handles during a launch is
 * forwarded or refunded before the call returns.
 */
contract FlaunchZap is IFlaunchZap {
    using PoolIdLibrary for PoolKey;

    /// The Flaunch {PositionManager} that launches are forwarded to
    PositionManager public immutable positionManager;

    /// The {Flaunch} ERC721 that represents ownership of a flaunched pool
    Flaunch public immutable flaunchContract;

    /// The factory used to deploy / recognise treasury managers. May be `address(0)` on chains
    /// where no factory has been deployed yet: manager flaunches then fall through to the
    /// unknown-manager path (approve + best-effort deposit + transfer), and
    /// {deployAndInitializeManager} reverts.
    ITreasuryManagerFactory public immutable treasuryManagerFactory;

    /**
     * References the contract addresses for the Flaunch protocol.
     *
     * @param _positionManager The Flaunch {PositionManager} contract
     * @param _flaunchContract The {Flaunch} ERC721 contract
     * @param _treasuryManagerFactory The {ITreasuryManagerFactory}, or `address(0)` if none exists
     */
    constructor(
        PositionManager _positionManager,
        Flaunch _flaunchContract,
        ITreasuryManagerFactory _treasuryManagerFactory
    ) {
        positionManager = _positionManager;
        flaunchContract = _flaunchContract;
        treasuryManagerFactory = _treasuryManagerFactory;
    }

    /**
     * Flaunches a memecoin without any additional logic.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     */
    function flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner
    ) external payable refundsEth returns (address memecoin_, uint ethSpent_) {
        return _flaunch(_flaunchParams, _trustedFeeSigner);
    }

    /**
     * Flaunches a memecoin and escrows it into a treasury manager.
     *
     * The zap flaunches with itself as the temporary creator so that it receives the Flaunch
     * ERC721, then wires the manager (see {_createWithManagerZap}) and deposits the token into it
     * on behalf of the original creator. Any premined memecoin is swept to the original creator.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _treasuryManagerParams Optional manager wiring for the new pool
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     * @return deployedManager_ The manager the flaunch token was deposited into
     */
    function flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        TreasuryManagerParams calldata _treasuryManagerParams,
        address _trustedFeeSigner
    ) external payable refundsEth returns (address memecoin_, uint ethSpent_, address deployedManager_) {
        return _flaunch(_flaunchParams, _treasuryManagerParams, _trustedFeeSigner);
    }

    /**
     * Deploys and initializes a manager instance from an approved implementation, setting its
     * permissions before handing ownership to `_owner`.
     *
     * @param _managerImplementation The approved manager implementation to clone
     * @param _owner The final owner of the deployed manager
     * @param _data Initialization data passed to the manager
     * @param _permissions The permissions contract set against the manager
     *
     * @return manager_ The deployed manager instance
     */
    function deployAndInitializeManager(
        address _managerImplementation,
        address _owner,
        bytes calldata _data,
        address _permissions
    ) public returns (address payable manager_) {
        if (address(treasuryManagerFactory) == address(0)) {
            revert TreasuryManagerFactoryNotSet();
        }

        manager_ = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: _managerImplementation,
            _owner: address(this),
            _data: _data
        });

        ITreasuryManager(manager_).setPermissions(_permissions);
        ITreasuryManager(manager_).transferManagerOwnership(_owner);
    }

    /**
     * Quotes the ETH a caller needs to supply for a launch: the flaunch fee plus the cost of any
     * premine, with an optional slippage buffer applied on top.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _slippage Optional slippage buffer, in basis points (100_00 == 100%)
     *
     * @return ethRequired_ The ETH the caller must send with the launch
     */
    function calculateFee(
        IPositionManager.FlaunchParams memory _flaunchParams,
        uint _slippage
    ) public view returns (uint ethRequired_) {
        uint premineCost = positionManager.getFlaunchingMarketCap(_flaunchParams.initialPriceParams) * _flaunchParams.premineAmount
            / TokenSupply.INITIAL_SUPPLY;

        ethRequired_ = positionManager.getFlaunchingFee(_flaunchParams.initialPriceParams) + premineCost;
        if (_slippage != 0) {
            ethRequired_ += ethRequired_ * _slippage / 100_00;
        }
    }

    /**
     * Convenience wrapper for launches without a treasury manager.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     */
    function _flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner
    ) internal returns (address memecoin_, uint ethSpent_) {
        // A zero-value manager struct means no manager is wired for this launch
        TreasuryManagerParams memory noManagerParams;
        (memecoin_, ethSpent_,) = _flaunch(_flaunchParams, noManagerParams, _trustedFeeSigner);
    }

    /**
     * The core launch routine that all entrypoints funnel into: flaunches the memecoin, reports
     * the ETH spent and, if requested, escrows the flaunched token into a treasury manager.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _treasuryManagerParams Optional manager wiring for the new pool
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     * @return deployedManager_ The manager the flaunch token was deposited into
     */
    function _flaunch(
        IPositionManager.FlaunchParams memory _flaunchParams,
        TreasuryManagerParams memory _treasuryManagerParams,
        address _trustedFeeSigner
    ) internal returns (address memecoin_, uint ethSpent_, address deployedManager_) {
        address originalCreator = _flaunchParams.creator;
        if (originalCreator == address(0)) {
            revert CreatorCannotBeZero();
        }

        // When a manager is requested, the zap becomes the temporary creator so that it receives
        // the Flaunch ERC721 (and any premine) and can deposit the token into the manager. The
        // trusted-signer path inside {_flaunchMemecoin} sees `creator == address(this)` and skips
        // its own NFT return / premine sweep, so both are handled exclusively below.
        bool hasManager = _treasuryManagerParams.manager != address(0);
        if (hasManager) {
            _flaunchParams.creator = address(this);
        }

        memecoin_ = _flaunchMemecoin(_flaunchParams, _trustedFeeSigner);

        // The ETH spent is the flaunch fee plus the ETH-funded premine cost
        ethSpent_ = positionManager.getFlaunchingFee(_flaunchParams.initialPriceParams)
            + (positionManager.getFlaunchingMarketCap(_flaunchParams.initialPriceParams)
                * _flaunchParams.premineAmount
                / TokenSupply.INITIAL_SUPPLY);

        if (hasManager) {
            deployedManager_ = _createWithManagerZap(memecoin_, originalCreator, _treasuryManagerParams);

            // The manager takes only the ERC721; any premine was delivered to the zap as the
            // temporary creator, so sweep it to the original creator so it is not stranded.
            uint memecoinBalance = IERC20(memecoin_).balanceOf(address(this));
            if (memecoinBalance != 0) {
                SafeTransferLib.safeTransfer(memecoin_, originalCreator, memecoinBalance);
            }
        }
    }

    /**
     * Performs the {PositionManager} flaunch call, registering a trusted fee signer against the
     * created pool if one was supplied.
     *
     * Registering a signer can only be done by the pool creator, so the zap makes itself the
     * temporary creator for the launch and afterwards forwards the ERC721 and any premined
     * memecoin to the original creator. If the creator was already set to this zap by the manager
     * flow, that forwarding is skipped and ownership is handled by the caller instead.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     *
     * @return memecoin_ The created ERC20 token address
     */
    function _flaunchMemecoin(
        IPositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner
    ) internal returns (address memecoin_) {
        // Without a signer there is nothing for the zap to do post-launch; forward the call as-is
        if (_trustedFeeSigner == address(0)) {
            memecoin_ = positionManager.flaunch{value: msg.value}(_flaunchParams);
            return memecoin_;
        }

        // Become the temporary creator so that the zap is allowed to register the signer
        address originalCreator = _flaunchParams.creator;
        if (originalCreator != address(this)) {
            _flaunchParams.creator = address(this);
        }

        memecoin_ = positionManager.flaunch{value: msg.value}(_flaunchParams);

        // Register the trusted signer against the pool that was just created
        PoolKey memory createdPoolKey = positionManager.poolKey(memecoin_);
        ITrustedSignerFeeCalculator(address(positionManager.feeCalculator()))
            .setTrustedPoolKeySigner({_poolKey: createdPoolKey, _signer: _trustedFeeSigner});

        // Forward the Flaunch ERC721 to the original creator
        if (originalCreator != address(this)) {
            flaunchContract.transferFrom(address(this), originalCreator, flaunchContract.tokenId(memecoin_));
        }

        // The premine is delivered to the flaunch `creator`, which is temporarily set to this
        // zap so it can register the trusted signer. Sweep any premined memecoin back to the
        // original creator so it is not stranded in the zap.
        uint memecoinBalance = IERC20(memecoin_).balanceOf(address(this));
        if (memecoinBalance != 0 && originalCreator != address(this)) {
            SafeTransferLib.safeTransfer(memecoin_, originalCreator, memecoinBalance);
        }
    }

    /**
     * Escrows a freshly flaunched token (held by this zap as the temporary creator) into a
     * treasury manager, dispatching on what the manager address is:
     *
     *  1. An approved manager implementation -> deploy + initialize a fresh instance through the
     *     factory and deposit into it, optionally applying permissions before handing the manager
     *     ownership to the creator.
     *  2. An instance previously deployed by the factory -> deposit into it directly.
     *  3. An unknown address -> best-effort `deposit` and, if the zap still holds the ERC721
     *     afterwards, transfer it to the address directly.
     *
     * If no factory is bound to this zap (`address(0)`), every manager routes through (3).
     *
     * @param _memecoin The flaunched memecoin whose ERC721 is being escrowed
     * @param _creator The original creator that the deposit is made on behalf of
     * @param _treasuryManagerParams The manager wiring requested by the caller
     *
     * @return deployedManager_ The manager the flaunch token was deposited into
     */
    function _createWithManagerZap(
        address _memecoin,
        address _creator,
        TreasuryManagerParams memory _treasuryManagerParams
    ) internal returns (address deployedManager_) {
        uint tokenId = flaunchContract.tokenId(_memecoin);
        ITreasuryManager.FlaunchToken memory flaunchToken =
            ITreasuryManager.FlaunchToken({flaunch: flaunchContract, tokenId: tokenId});

        bool hasFactory = address(treasuryManagerFactory) != address(0);

        if (hasFactory && treasuryManagerFactory.approvedManagerImplementation(_treasuryManagerParams.manager)) {
            // If permissions will be applied, the zap must own the manager while it sets them, and
            // only hands ownership to the creator afterwards.
            address initialOwner = _treasuryManagerParams.permissions == address(0) ? _creator : address(this);
            deployedManager_ = treasuryManagerFactory.deployAndInitializeManager({
                _managerImplementation: _treasuryManagerParams.manager,
                _owner: initialOwner,
                _data: _treasuryManagerParams.initializeData
            });

            flaunchContract.approve(deployedManager_, tokenId);
            ITreasuryManager(deployedManager_).deposit({
                _flaunchToken: flaunchToken,
                _creator: _creator,
                _data: _treasuryManagerParams.depositData
            });

            if (_treasuryManagerParams.permissions != address(0)) {
                ITreasuryManager(deployedManager_).setPermissions(_treasuryManagerParams.permissions);
                ITreasuryManager(deployedManager_).transferManagerOwnership(_creator);
            }
        } else if (hasFactory && treasuryManagerFactory.managerImplementation(_treasuryManagerParams.manager) != address(0)) {
            flaunchContract.approve(_treasuryManagerParams.manager, tokenId);
            deployedManager_ = _treasuryManagerParams.manager;
            ITreasuryManager(deployedManager_).deposit({
                _flaunchToken: flaunchToken,
                _creator: _creator,
                _data: _treasuryManagerParams.depositData
            });
        } else {
            flaunchContract.approve(_treasuryManagerParams.manager, tokenId);

            try ITreasuryManager(_treasuryManagerParams.manager).deposit(
                flaunchToken, _creator, _treasuryManagerParams.depositData
            ) {} catch {}

            if (flaunchContract.ownerOf(tokenId) == address(this)) {
                flaunchContract.transferFrom(address(this), _treasuryManagerParams.manager, tokenId);
            }

            deployedManager_ = _treasuryManagerParams.manager;
        }
    }

    /**
     * Refunds any ETH left in the zap after the call to the caller, so nothing is stranded.
     */
    modifier refundsEth() {
        _;

        uint remainingBalance = payable(address(this)).balance;
        if (remainingBalance != 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
        }
    }

    /// Allows the {PositionManager} to refund unspent ETH during a launch
    receive() external payable {}
}
