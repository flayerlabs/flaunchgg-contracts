// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SafeCast} from '@uniswap/v4-core/src/libraries/SafeCast.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {Flaunch} from '@flaunch/Flaunch.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {TokenSupply} from '@flaunch/libraries/TokenSupply.sol';
import {WhitelistFairLaunch} from '@flaunch/subscribers/WhitelistFairLaunch.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {IMerkleAirdrop} from '@flaunch-interfaces/IMerkleAirdrop.sol';
import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';
import {ITreasuryManagerFactory} from '@flaunch-interfaces/ITreasuryManagerFactory.sol';
import {ITrustedSignerFeeCalculator} from '@flaunch-interfaces/ITrustedSignerFeeCalculator.sol';


/**
 * Allows a token to be flaunched with all additional layers of customisation added to
 * facilitate a single transaction.
 *
 * @dev When new functionality is introduced, this zap should be updated with it and deployed
 * against to ensure we have a single contract as a flaunching entry point.
 */
contract FlaunchZap {

    using SafeCast for uint;

    error CreatorCannotBeZero();
    error InsufficientMemecoinsForAirdrop();

    /// The Flaunch {PositionManager} contract
    PositionManager public immutable positionManager;

    /// The Flaunch {Flaunch} contract
    Flaunch public immutable flaunchContract;

    /// The underlying flETH token paired against the created token
    IFLETH public immutable flETH;

    /// The swap contract being used to perform the token buy
    PoolSwap public immutable poolSwap;

    /// Airdrop contracts
    IMerkleAirdrop public immutable merkleAirdrop;

    /// TreasuryManager contracts
    ITreasuryManagerFactory public immutable treasuryManagerFactory;

    /// Whitelist contracts
    WhitelistFairLaunch public immutable whitelistFairLaunch;

    /**
     * Allows the creator to disperse their premined tokens as a claimable airdrop.
     *
     * @param airdropIndex The index of the airdrop
     * @param airdropAmount The amount of memecoins to add to the airdrop
     * @param airdropEndTime The timestamp at which the airdrop ends
     * @param merkleRoot The merkle root for the airdrop
     * @param merkleIPFSHash The IPFS hash of the merkle data
     */
    struct AirdropParams {
        uint airdropIndex;
        uint airdropAmount;
        uint airdropEndTime;
        bytes32 merkleRoot;
        string merkleIPFSHash;
    }

    /**
     * If the manager is an approved implementation, then it's instance will be deployed. Otherwise
     * the flaunch token will be transferred directly to the manager.
     *
     * @param manager The manager implementation to use
     * @param permissions The permissions contract to use for a newly deployed manager
     * @param initializeData The data to initialize the manager with
     * @param depositData The data to deposit to the manager with
     */
    struct TreasuryManagerParams {
        address manager;
        address permissions;
        bytes initializeData;
        bytes depositData;
    }

    /**
     * Creates a whitelist of users that can make swaps during fair launch.
     *
     * @param _merkleRoot The merkle root for the airdrop
     * @param _merkleIPFSHash The IPFS hash of the merkle data
     * @param _whitelistMaxTokens The amount of tokens a user can buy during whitelist
     */
    struct WhitelistParams {
        bytes32 merkleRoot;
        string merkleIPFSHash;
        uint maxTokens;
    }

    /**
     * Assigns the immutable contracts used by the zap.
     *
     * @param _positionManager Flaunch {PositionManager}
     * @param _flaunchContract Flaunch contract
     * @param _flETH Underlying flETH token
     * @param _poolSwap Swap contract for premining
     * @param _treasuryManagerFactory The Treasury Manager Factory contract
     * @param _merkleAirdrop The contract to facilitate airdrops
     * @param _whitelistFairLaunch The {WhitelistFairLaunch} contract address
     */
    constructor (
        PositionManager _positionManager,
        Flaunch _flaunchContract,
        IFLETH _flETH,
        PoolSwap _poolSwap,
        ITreasuryManagerFactory _treasuryManagerFactory,
        IMerkleAirdrop _merkleAirdrop,
        WhitelistFairLaunch _whitelistFairLaunch
    ) {
        positionManager = _positionManager;
        flaunchContract = _flaunchContract;
        flETH = _flETH;
        poolSwap = _poolSwap;
        treasuryManagerFactory = _treasuryManagerFactory;
        merkleAirdrop = _merkleAirdrop;
        whitelistFairLaunch = _whitelistFairLaunch;
    }

    /**
     * Flaunches a memecoin without any additional logic.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     * @param _premineSwapHookData data passed to the premine swap hook, containing referrer & SignedMessage for trusted signer
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     * @return deployedManager_ The address of the manager that was deployed
     */
    function flaunch(
        PositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner,
        bytes calldata _premineSwapHookData
    ) external payable refundsEth returns (address memecoin_, uint ethSpent_, address) {
        // Flaunch our token and capture the memecoin address
        memecoin_ = _flaunch(_flaunchParams, _trustedFeeSigner);

        // Allows the creator to premine their own token
        if (_flaunchParams.premineAmount != 0) {
            // Premine tokens to this contract
            ethSpent_ = _premine(memecoin_, _flaunchParams.premineAmount, _premineSwapHookData);

            // Send any remaining premined memecoins to the creator
            uint remainingMemecoins = IERC20(memecoin_).balanceOf(address(this));
            if (remainingMemecoins != 0) {
                IERC20(memecoin_).transfer(_flaunchParams.creator, remainingMemecoins);
            }
        }
    }

    /**
     * Flaunches a memecoin whilst allowing for any additional logic.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Optional trusted fee signer for this memecoin
     * @param _premineSwapHookData data passed to the premine swap hook, containing referrer & SignedMessage for trusted signer
     * @param _whitelistParams Whitelist related flaunch logic
     * @param _airdropParams Airdrop related flaunch logic
     * @param _treasuryManagerParams Treasury Manager related flaunch logic
     *
     * @return memecoin_ The created ERC20 token address
     * @return ethSpent_ The amount of ETH spent during the premine
     * @return deployedManager_ The address of the manager that was deployed
     */
    function flaunch(
        PositionManager.FlaunchParams memory _flaunchParams,
        address _trustedFeeSigner,
        bytes calldata _premineSwapHookData,
        WhitelistParams calldata _whitelistParams,
        AirdropParams calldata _airdropParams,
        TreasuryManagerParams calldata _treasuryManagerParams
    ) external payable refundsEth returns (address memecoin_, uint ethSpent_, address deployedManager_) {
        // Map the original creator throughout, even if it overwritten by a treasury manager
        address creator = _flaunchParams.creator;
        if (creator == address(0)) revert CreatorCannotBeZero();

        // If we are setting up a TreasuryManager then we need to ensure that the creator is
        // updated to this zap contract.
        if (_treasuryManagerParams.manager != address(0)) {
            _flaunchParams.creator = address(this);
        }

        // Flaunch our token and capture the memecoin address
        memecoin_ = _flaunch(_flaunchParams, _trustedFeeSigner);

        // Allows the creator to premine their own token
        if (_flaunchParams.premineAmount != 0) {
            // Premine tokens to this contract
            ethSpent_ = _premine(memecoin_, _flaunchParams.premineAmount, _premineSwapHookData);

            // Check if we are airdropping any of the tokens that we premined
            if (_airdropParams.airdropAmount != 0) {
                _airdrop(memecoin_, creator, _airdropParams);
            }

            // Send any remaining premined memecoins to the creator
            uint remainingMemecoins = IERC20(memecoin_).balanceOf(address(this));
            if (remainingMemecoins != 0) {
                IERC20(memecoin_).transfer(creator, remainingMemecoins);
            }
        }

        // If we have whitelist data for the flaunch, then we can create our whitelist logic. This
        // must be done after tokens have been premined to prevent the premine from being rejected
        // in the instance that the creator did not whitelist themselves.
        if (_flaunchParams.initialTokenFairLaunch != 0 && _whitelistParams.merkleRoot != '') {
            _createWhitelist(memecoin_, _whitelistParams);
        }

        // If we are transferring the token to a manager, then we can specify this here
        if (_treasuryManagerParams.manager != address(0)) {
            deployedManager_ = _createWithManagerZap(memecoin_, creator, _treasuryManagerParams);
        }
    }

    /**
     * Deploys an approved manager, initializes it and sets permissions in a single transaction.
     *
     * @param _managerImplementation The address of the approved implementation
     * @param _owner The owner address of the manager
     * @param _data The initialization data for the deployed manager
     * @param _permissions The permissions contract to use for the manager
     *
     * @return manager_ The freshly deployed {TreasuryManager} contract address
     */
    function deployAndInitializeManager(
        address _managerImplementation,
        address _owner,
        bytes calldata _data,
        address _permissions
    ) public returns (
        address payable manager_
    ) {
        // Deploy our manager implementation
        manager_ = treasuryManagerFactory.deployAndInitializeManager({
            _managerImplementation: _managerImplementation,
            _owner: address(this),
            _data: _data
        });

        // Set the permissions for the manager
        ITreasuryManager(manager_).setPermissions(_permissions);

        // Set the owner to the actual owner
        ITreasuryManager(manager_).transferManagerOwnership(_owner);
    }

    /**
     * Flaunches our base ERC20.
     *
     * @param _flaunchParams The base flaunch parameters
     * @param _trustedFeeSigner Custom trusted fee signer for this memecoin
     *
     * @return memecoin_ The address of the flaunched ERC20 token
     */
    function _flaunch(PositionManager.FlaunchParams memory _flaunchParams, address _trustedFeeSigner) internal returns (address memecoin_) {
        // if no trusted fee signer is provided, then we flaunch as normal
        if (_trustedFeeSigner == address(0)) {
            memecoin_ = positionManager.flaunch{value: msg.value}(_flaunchParams);
        } else {
            // `setTrustedPoolKeySigner` can only be called by the current creator
            // so we make this contract as the creator for now

            // in case we are flaunching into a treasury manager, the creator is already temporarily set as this contract
            address originalCreator = _flaunchParams.creator;
            if (originalCreator != address(this)) {
                _flaunchParams.creator = address(this);
            }

            // flaunch the token
            memecoin_ = positionManager.flaunch{value: msg.value}(_flaunchParams);
            
            // set the trusted fee signer for this memecoin
            ITrustedSignerFeeCalculator(address(positionManager.getFeeCalculator(true))).setTrustedPoolKeySigner({
                _poolKey: positionManager.poolKey(memecoin_),
                _signer: _trustedFeeSigner
            });

            // if the creator was not this contract, we need to send the flaunch NFT to the original creator
            if (originalCreator != address(this)) {
                flaunchContract.transferFrom(
                    address(this),
                    originalCreator,
                    flaunchContract.tokenId(memecoin_)
                );
            }
        }
    }

    /**
     * If we have a treasury manager defined, then we process additional logic to transfer the ERC721
     * to the defined Treasury Manager contract.
     *
     * @dev If the manager is an approved implementation, then it's instance will be deployed. Otherwise
     * the flaunch token will be transferred directly to the manager.
     *
     * @param _memecoin The address of the flaunched ERC20
     * @param _creator The original creator of the ERC721
     * @param _treasuryManagerParams Treasury Manager related flaunch logic
     *
     * @return deployedManager_ The address of the manager that the ERC721 has been sent to
     */
    function _createWithManagerZap(
        address _memecoin,
        address _creator,
        TreasuryManagerParams calldata _treasuryManagerParams
    ) internal returns (address deployedManager_) {
        // Get the token ID of the flaunch token
        uint tokenId = flaunchContract.tokenId(_memecoin);

        // Send the flaunch token to the manager
        if (treasuryManagerFactory.approvedManagerImplementation(_treasuryManagerParams.manager)) {
            // If it is a valid manager implementation, deploy a new instance
            address initialOwner = _treasuryManagerParams.permissions == address(0) ? _creator : address(this);
            deployedManager_ = treasuryManagerFactory.deployAndInitializeManager({
                _managerImplementation: _treasuryManagerParams.manager,
                _owner: initialOwner,
                _data: _treasuryManagerParams.initializeData
            });

            // Approve the manager to pull the flaunch token during initialization
            flaunchContract.approve(deployedManager_, tokenId);

            ITreasuryManager(deployedManager_).deposit({
                _flaunchToken: ITreasuryManager.FlaunchToken({
                    flaunch: flaunchContract,
                    tokenId: tokenId
                }),
                _creator: _creator,
                _data: _treasuryManagerParams.depositData
            });

            // if permissions are provided for the new manager, then set them
            if (_treasuryManagerParams.permissions != address(0)) {
                ITreasuryManager(deployedManager_).setPermissions(_treasuryManagerParams.permissions);

                // transfer ownership to the creator
                ITreasuryManager(deployedManager_).transferManagerOwnership(_creator);
            }
        } else if (treasuryManagerFactory.managerImplementation(_treasuryManagerParams.manager) != address(0)) {
            // Approve the manager to pull the flaunch token during initialization
            flaunchContract.approve(_treasuryManagerParams.manager, tokenId);

            ITreasuryManager(_treasuryManagerParams.manager).deposit({
                _flaunchToken: ITreasuryManager.FlaunchToken({
                    flaunch: flaunchContract,
                    tokenId: tokenId
                }),
                _creator: _creator,
                _data: _treasuryManagerParams.depositData
            });
        } else {
            // If it's not a valid manager implementation, transfer the flaunch token directly
            // to the manager contract address specified.
            deployedManager_ = _treasuryManagerParams.manager;
            flaunchContract.transferFrom(address(this), deployedManager_, tokenId);
        }
    }

    /**
     * If a whitelist merkle has been provided, register a whitelist of users that will be able
     * to claim from the fair launch allocation.
     *
     * @param _memecoin The address of the flaunched ERC20
     * @param _whitelistParams Whitelist related flaunch logic
     */
    function _createWhitelist(address _memecoin, WhitelistParams calldata _whitelistParams) internal {
        whitelistFairLaunch.setWhitelist({
            _poolId: positionManager.poolKey(_memecoin).toId(),
            _root: _whitelistParams.merkleRoot,
            _ipfs: _whitelistParams.merkleIPFSHash,
            _maxTokens: _whitelistParams.maxTokens
        });
    }

    /**
     * If we have a premine amount provided, the creator can purchase some of their initial fair
     * launch supply during the same transaction.
     *
     * @param _memecoin The address of the flaunched ERC20
     * @param _premineAmount The amount of tokens the user wants to purchase from initial supply
     * @param _premineSwapHookData data passed to the premine swap hook, containing referrer & SignedMessage for trusted signer
     *
     * @return ethSpent_ The amount of ETH spent during the premine
     */
    function _premine(address _memecoin, uint _premineAmount, bytes calldata _premineSwapHookData) internal returns (uint ethSpent_) {
        // Capture the PoolKey that was created during the 'flaunch'
        PoolKey memory _poolKey = positionManager.poolKey(_memecoin);

        // Calculate the amount of ETH being used for the premine
        uint _ethAmount = payable(address(this)).balance;

        // Wrapping ETH into flETH
        flETH.deposit{value: _ethAmount}(0);

        // Check if we have a flipped pool
        bool flipped = Currency.unwrap(_poolKey.currency0) != address(flETH);

        // Give {PoolSwap} unlimited flETH allowance if we don't already have a
        // sufficient allowance.
        if (flETH.allowance(address(this), address(poolSwap)) < _ethAmount) {
            flETH.approve(address(poolSwap), type(uint).max);
        }

        // Action our swap on the {PoolSwap} contract with max range
        BalanceDelta delta = poolSwap.swap({
            _key: _poolKey,
            _params: IPoolManager.SwapParams({
                zeroForOne: !flipped,
                amountSpecified: _premineAmount.toInt256(),
                sqrtPriceLimitX96: !flipped
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            _hookData: _premineSwapHookData
        });

        // Calculate the amount of flETH swapped from the delta
        ethSpent_ = uint128(!flipped ? -delta.amount0() : -delta.amount1());

        // If there is ETH remaining after the user has made their swap, then we want
        // to unwrap it back into ETH so that the calling function can return it.
        uint remainingETH = _ethAmount - ethSpent_;
        if (remainingETH != 0) {
            flETH.withdraw(remainingETH);
        }
    }

    /**
     * If an airdrop merkle has been provided and some amount of tokens have been premined, we create
     * an airdrop that allows the addresses present in the merkle to claim them.
     *
     * @param _memecoin The address of the flaunched ERC20
     * @param _creator The original creator of the ERC721
     * @param _airdropParams Airdrop related flaunch logic
     */
    function _airdrop(address _memecoin, address _creator, AirdropParams calldata _airdropParams) internal {
        // Find the total number of tokens that we premined
        uint memecoinsPremined = IERC20(_memecoin).balanceOf(address(this));

        // Ensure that the number of tokens that we premined will cover the amount that the
        // creator has requested that we airdrop.
        if (memecoinsPremined < _airdropParams.airdropAmount) {
            revert InsufficientMemecoinsForAirdrop();
        }

        // Add the memecoin airdrop to the merkle airdrop contract
        IERC20(_memecoin).approve(address(merkleAirdrop), _airdropParams.airdropAmount);
        merkleAirdrop.addAirdrop({
            _creator: _creator,
            _airdropIndex: _airdropParams.airdropIndex,
            _token: _memecoin,
            _amount: _airdropParams.airdropAmount,
            _airdropEndTime: _airdropParams.airdropEndTime,
            _merkleRoot: _airdropParams.merkleRoot,
            _merkleDataIPFSHash: _airdropParams.merkleIPFSHash
        });
    }

    /**
     * Calculates the fee that will be required to use the zap with the specified premine. This allows
     * for a slippage amount to be set, just incase we want to provide some buffer on the call.
     *
     * @param _premineAmount The number of tokens to be premined
     * @param _slippage The slippage percentage with 2dp
     *
     * @return ethRequired_ The amount of ETH that will be required
     */
    function calculateFee(uint _premineAmount, uint _slippage, bytes calldata _initialPriceParams) public view returns (uint ethRequired_) {
        // Market cap / total supply * premineAmount + swapFee
        uint premineCost = positionManager.getFlaunchingMarketCap(_initialPriceParams) * _premineAmount / TokenSupply.INITIAL_SUPPLY;

        // Create a fake pool key, just to generate an non-existant ID to check against
        PoolKey memory fakePoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Calculate swap fee
        IFeeCalculator feeCalculator = positionManager.getFeeCalculator(true);
        uint24 baseSwapFee = positionManager.getPoolFeeDistribution(fakePoolKey.toId()).swapFee;
        if (address(feeCalculator) != address(0)) {
            baseSwapFee = feeCalculator.determineSwapFee({
                _poolKey: fakePoolKey,
                _params: IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: _premineAmount.toInt256(),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE
                }),
                _baseFee: baseSwapFee
            });
        }

        // Set our base requirement of fee and premine market cost
        ethRequired_ = positionManager.getFlaunchingFee(_initialPriceParams) + premineCost;

        // Add our fee if present
        if (baseSwapFee != 0) {
            ethRequired_ += premineCost * baseSwapFee / 100_00;
        }

        // Add slippage
        if (_slippage != 0) {
            ethRequired_ += ethRequired_ * _slippage / 100_00;
        }
    }

    /**
     * Returns any ETH remaining in the contract to the `msg.sender` after the transaction.
     */
    modifier refundsEth {
        _;

        // Refund the remaining ETH
        uint remainingBalance = payable(address(this)).balance;
        if (remainingBalance != 0) {
            SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
        }
    }

    /**
     * To receive ETH from flETH on withdraw.
     */
    receive() external payable {}

}
