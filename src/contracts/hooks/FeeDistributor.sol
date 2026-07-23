// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';
import {ReferralEscrow} from '@flaunch/escrows/ReferralEscrow.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

/**
 * This hook will allow our pools to have a range of fee distribution approaches. This will
 * fallback onto a global fee distribution if there is not a specific.
 */
abstract contract FeeDistributor is Ownable {
    using MemecoinFinder for PoolKey;
    using PoolIdLibrary for PoolKey;

    error CallerNotCreator(address _caller);
    error CreatorFeeAllocationInvalid(uint24 _allocation);
    error RecipientZeroAddress();
    error ProtocolFeeInvalid();
    error ReferrerFeeInvalid();
    error SwapFeeInvalid();

    /// Emitted when our `FeeDistribution` struct is modified
    event FeeDistributionUpdated(FeeDistribution _feeDistribution);

    /// Emitted when our `FeeDistribution` struct is modified for a pool
    event PoolFeeDistributionUpdated(PoolId indexed _poolId, FeeDistribution _feeDistribution);

    /// Emitted when our {FeeCalculator} contract is updated
    event FeeCalculatorUpdated(address _feeCalculator);

    /// Emitted when a pool's fees have been distributed to its recipients
    event PoolFeesDistributed(
        PoolId indexed _poolId, uint _donateAmount, uint _creatorAmount, uint _bidWallAmount, uint _governanceAmount, uint _protocolAmount
    );

    /// Emitted when a pool's creator fee allocation is updated
    event CreatorFeeAllocationUpdated(PoolId indexed _poolId, uint24 _allocation);

    /// Emitted when a referrer fee has been paid out
    event ReferrerFeePaid(PoolId indexed _poolId, address _recipient, address _token, uint _amount);

    /// Emitted when the {ReferralEscrow} contract is updated
    event ReferralEscrowUpdated(address _referralEscrow);

    /**
     * Stores the percentages of fee distribution.
     *
     * @dev This works in a waterfall approach, with a percentage taking a share before
     * passing the potential allocation on to the next. This means that the percentages
     * listed don't need to equal 100%:
     *
     * `Fee priority: swapfee -> referrer -> protocol -> creator -> bidwall`
     *
     * @member swapFee The amount of the transaction taken as fee
     * @member referrer The percentage that the referrer will receive
     * @member protocol The percentage that the protocol will receive
     * @member active If a FeeDistribution struct has been set for the mapping
     */
    struct FeeDistribution {
        uint24 swapFee;
        uint24 referrer;
        uint24 protocol;
        bool active;
    }

    /// Helpful constant to define 100% to 2dp
    uint internal constant ONE_HUNDRED_PERCENT = 100_00;

    /// The maximum value of a protocol fee allocation
    uint24 public constant MAX_PROTOCOL_ALLOCATION = 10_00;

    /// Maps the creators share of the fee distribution that can be set by the creator
    /// to reduce fees from hitting the bidwall.
    mapping(PoolId _poolId => uint24 _creatorFee) internal creatorFee;

    /// Maps individual pools to custom `FeeDistribution`s. These will overwrite the
    /// global `feeDistribution`.
    mapping(PoolId _poolId => FeeDistribution _feeDistribution) internal poolFeeDistribution;

    /// Maps our IERC20 token addresses to their registered PoolKey
    mapping(address _memecoin => PoolKey _poolKey) internal _poolKeys;

    /// The global FeeDistribution that will be applied to all pools
    FeeDistribution internal feeDistribution;

    /// The {ReferralEscrow} contract that will be used
    ReferralEscrow public referralEscrow;

    /// The {FeeEscrow} contract that will be used
    FeeEscrow public feeEscrow;

    /// The {IFeeCalculator} used to calculate swap fees
    IFeeCalculator public feeCalculator;

    /// Our internal native token
    address public nativeToken;

    /// The address of the $FLAY token's governance
    address public flayGovernance;

    /**
     * Set up our initial FeeDistribution data.
     *
     * @param _nativeToken Our internal native token
     * @param _feeDistribution The initial FeeDistribution value
     * @param _protocolOwner The initial EOA owner of the contract
     */
    constructor(
        address _nativeToken,
        FeeDistribution memory _feeDistribution,
        address _protocolOwner,
        address _flayGovernance,
        address _feeEscrow
    ) {
        nativeToken = _nativeToken;

        // Set our initial fee distribution
        _validateFeeDistribution(_feeDistribution);
        feeDistribution = _feeDistribution;
        emit FeeDistributionUpdated(_feeDistribution);

        // Set our $FLAY token governance address
        flayGovernance = _flayGovernance;

        // Set our fee escrow
        feeEscrow = FeeEscrow(payable(_feeEscrow));

        // Grant ownership permissions to the caller
        if (owner() == address(0)) {
            _initializeOwner(_protocolOwner);
        }
    }

    /**
     * Allows a deposit to be made against a user. The amount is stored within the
     * {FeeEscrow} contract to be claimed later.
     *
     * @param _poolId The PoolId that the deposit came from
     * @param _recipient The recipient of the transferred token
     * @param _amount The amount of the token to be transferred
     */
    function _allocateFees(
        PoolId _poolId,
        address _recipient,
        uint _amount
    ) internal {
        // set allowance so that `feeEscrow` can pull the fees
        if (IFLETH(nativeToken).allowance(msg.sender, address(feeEscrow)) < _amount) {
            IFLETH(nativeToken).approve(address(feeEscrow), type(uint).max);
        }

        // allocate the fees in the escrow
        feeEscrow.allocateFees(_poolId, _recipient, _amount);
    }

    /**
     * Captures fees following a swap.
     *
     * @param _poolManager The Uniswap V4 {PoolManager}
     * @param _key The key for the pool being swapped against
     * @param _params The swap parameters called in the swap
     * @param _feeCalculator The fee calculator to use for calculations
     * @param _swapFeeCurrency The currency that the fee will be paid in
     * @param _swapAmount The amount of the swap to take fees from
     * @param _feeExemption The optional fee exemption that can overwrite
     *
     * @return swapFee_ The amount of fees taken for the swap
     */
    function _captureSwapFees(
        IPoolManager _poolManager,
        PoolKey calldata _key,
        SwapParams memory _params,
        IFeeCalculator _feeCalculator,
        Currency _swapFeeCurrency,
        uint _swapAmount,
        IFeeExemptions.FeeExemption memory _feeExemption
    ) internal returns (uint swapFee_) {
        // If we have an empty swapAmount then we can exit early
        if (_swapAmount == 0) {
            return swapFee_;
        }

        // Get our base swapFee from the FeeCalculator. If we don't have a feeCalculator
        // set, then we need to just use our base rate.
        uint24 baseSwapFee = getPoolFeeDistribution(_key.toId()).swapFee;

        // Check if we have a {FeeCalculator} attached to calculate the fee
        if (address(_feeCalculator) != address(0)) {
            baseSwapFee = _feeCalculator.determineSwapFee(_key, _params, baseSwapFee);
        }

        // If we have a swap fee override, then we want to use that value, only if it is
        // less than the traditionally calculated base swap fee.
        if (_feeExemption.enabled && _feeExemption.flatFee < baseSwapFee) {
            baseSwapFee = _feeExemption.flatFee;
        }

        // If we have an empty swapFee, then we don't need to process further
        if (baseSwapFee == 0) {
            return swapFee_;
        }

        // Determine our fee amount
        swapFee_ = _swapAmount * baseSwapFee / ONE_HUNDRED_PERCENT;

        // Take our swap fees from the {PoolManager}
        _poolManager.take(_swapFeeCurrency, address(this), swapFee_);
    }

    /**
     * Checks if a referrer has been set in the hookData and transfers them their share of
     * the fee directly. This call is made when a swap is taking place and returns the new
     * fee amount after the referrer fee has been removed from it.
     *
     * @param _key The pool key to distribute referrer fees for
     * @param _swapFeeCurrency The currency of the swap fee
     * @param _swapFee The total value of the swap fee
     * @param _hookData Hook data that may contain an encoded referrer address
     *
     * @return referrerFee_ The amount of `swapFeeCurrency` token given to referrer
     */
    function _distributeReferrerFees(
        PoolKey calldata _key,
        Currency _swapFeeCurrency,
        uint _swapFee,
        bytes calldata _hookData
    ) internal returns (uint referrerFee_) {
        // If we have no hook data, then this is a low-gas exit point
        if (_hookData.length == 0) {
            return referrerFee_;
        }

        // Check if we have a specific pool FeeDistribution that overwrites the global value
        PoolId poolId = _key.toId();
        uint24 referrerShare = getPoolFeeDistribution(poolId).referrer;

        // If we have no referrer fee set, then we can exit without paying a fee
        if (referrerShare == 0) {
            return referrerFee_;
        }

        // Decode our referrer address
        (address referrer) = abi.decode(_hookData, (address));

        // If we have a zero address referrer, then we can exit early
        if (referrer == address(0)) {
            return referrerFee_;
        }

        // If we have a referrer then instantly cut them _x%_ of the swap result
        referrerFee_ = _swapFee * referrerShare / ONE_HUNDRED_PERCENT;

        // If we don't have referral escrow, send direct to user. We use an unsafe transfer so that
        // invalid addresses don't prevent the process.
        if (address(referralEscrow) == address(0)) {
            _swapFeeCurrency.transfer(referrer, referrerFee_);
            emit ReferrerFeePaid(poolId, referrer, Currency.unwrap(_swapFeeCurrency), referrerFee_);
        }
        // Transfer referrer fees to the escrow contract that they can claim or swap for later
        else {
            _swapFeeCurrency.transfer(address(referralEscrow), referrerFee_);
            referralEscrow.assignTokens(poolId, referrer, Currency.unwrap(_swapFeeCurrency), referrerFee_);
        }
    }

    /**
     * Taking an amount, show the split that each of the different recipients will receive.
     *
     * @dev Fee priority: swapfee -> referrer -> || protocol -> creator -> bidwall ||
     *
     * @param _poolId The PoolId that is having the fee split calculated
     * @param _amount The amount of token being passed in
     *
     * @return bidWall_ The amount that the PBW will receive
     * @return creator_ The amount that the token creator will receive
     * @return protocol_ The amount that the protocol will receive
     */
    function feeSplit(
        PoolId _poolId,
        uint _amount
    ) public view returns (uint bidWall_, uint creator_, uint protocol_) {
        // Check if we have a pool overwrite for the FeeDistribution
        FeeDistribution memory _poolFeeDistribution = getPoolFeeDistribution(_poolId);

        // Take the protocol share
        if (_poolFeeDistribution.protocol != 0) {
            protocol_ = _amount * _poolFeeDistribution.protocol / ONE_HUNDRED_PERCENT;
            _amount -= protocol_;
        }

        // The creator is now given their share
        uint24 _creatorFee = creatorFee[_poolId];
        if (_creatorFee != 0) {
            creator_ = _amount * _creatorFee / ONE_HUNDRED_PERCENT;
            _amount -= creator_;
        }

        // The bidwall will receive the remaining allocation
        bidWall_ = _amount;
    }

    /**
     * Updates the {ReferralEscrow} contract that will store referrer fees.
     *
     * @param _referralEscrow The new {ReferralEscrow} contract address
     */
    function setReferralEscrow(
        address payable _referralEscrow
    ) public onlyOwner {
        // Update our {ReferralEscrow} address
        referralEscrow = ReferralEscrow(_referralEscrow);
        emit ReferralEscrowUpdated(_referralEscrow);
    }

    /**
     * Allows the governing contract to make global changes to the fees.
     *
     * @param _feeDistribution The new FeeDistribution value
     */
    function setFeeDistribution(
        FeeDistribution memory _feeDistribution
    ) public onlyOwner {
        _validateFeeDistribution(_feeDistribution);

        // Update our FeeDistribution struct
        feeDistribution = _feeDistribution;
        emit FeeDistributionUpdated(_feeDistribution);
    }

    /**
     * Allows the $FLAY token governance to set the global protocol fee.
     *
     * @param _protocol New protocol fee
     */
    function setProtocolFeeDistribution(
        uint24 _protocol
    ) public {
        // Check that the caller is the $FLAY governance
        if (msg.sender != flayGovernance) {
            revert Unauthorized();
        }

        // Validate the range that the protocol fee can be
        if (_protocol > MAX_PROTOCOL_ALLOCATION) {
            revert ProtocolFeeInvalid();
        }

        // Update only the protocol fee in our `FeeDistribution`
        feeDistribution.protocol = _protocol;
        emit FeeDistributionUpdated(feeDistribution);
    }

    /**
     * Allows the governing contract to make pool specific changes to the fees.
     *
     * @param _poolId The PoolId being updated
     * @param _feeDistribution The new FeeDistribution value
     */
    function setPoolFeeDistribution(
        PoolId _poolId,
        FeeDistribution memory _feeDistribution
    ) public onlyOwner {
        _validateFeeDistribution(_feeDistribution);

        // Update our FeeDistribution struct
        poolFeeDistribution[_poolId] = _feeDistribution;
        emit PoolFeeDistributionUpdated(_poolId, _feeDistribution);
    }

    /**
     * Allows the holder of the {Flaunch} ERC721 to change the share of the pool fees that they
     * take ahead of the BidWall. The BidWall receives the remaining allocation, so lowering this
     * value increases the BidWall's share and raising it reduces the BidWall's share.
     *
     * @dev Taking the full allocation leaves the BidWall with nothing, so at that point any
     * existing BidWall position is unwound back to the {MemecoinTreasury} rather than being
     * left stranded in the pool with no future deposits to reposition it.
     *
     * @param _memecoin The memecoin whose pool is being updated
     * @param _allocation The new fee percentage allocation for the creator
     */
    function setCreatorFeeAllocation(
        address _memecoin,
        uint24 _allocation
    ) public {
        // Resolve the pool from our registered memecoins and ensure that the caller is the
        // current holder of the ERC721. An unregistered memecoin has a zero `tickSpacing`, so
        // this also prevents an arbitrary contract from spoofing a `creator` response.
        PoolKey memory _poolKey = _poolKeys[_memecoin];
        if (_poolKey.tickSpacing == 0 || msg.sender != _memecoinCreator(_memecoin)) {
            revert CallerNotCreator(msg.sender);
        }

        // The creator can take up to 100%, matching the cap applied at flaunch time
        if (_allocation > ONE_HUNDRED_PERCENT) {
            revert CreatorFeeAllocationInvalid(_allocation);
        }

        // We only need to process the following logic if anything is changing. Without this we
        // would re-emit an update that moved nothing, and repeat the BidWall closure against a
        // position that has already been unwound - which costs a {PoolManager} unlock and emits
        // a `BidWallClosed` that consumers would read as a real state transition. This mirrors
        // the same early exit in {BidWall.setDisabledState}.
        PoolId poolId = _poolKey.toId();
        if (creatorFee[poolId] == _allocation) {
            return;
        }

        // Update the creator fee allocation for the pool
        creatorFee[poolId] = _allocation;
        emit CreatorFeeAllocationUpdated(poolId, _allocation);

        // If the BidWall has been left without a share, then we unwind its position. Reaching
        // the full allocation is necessarily a transition, as the guard above returns early
        // otherwise, so the closure runs exactly once per time the BidWall is starved. The
        // BidWall cannot rebuild while the creator holds everything either, as `feeSplit`
        // leaves it a zero share and {_distributeFees} never reaches `deposit`.
        if (_allocation == ONE_HUNDRED_PERCENT) {
            _closeBidWall(_poolKey);
        }
    }

    /**
     * Resolves the current holder of the {Flaunch} ERC721 for a memecoin, which the protocol
     * treats as the pool creator.
     *
     * @dev This is overridden where the token is an imported ERC20 that has no `creator` call.
     *
     * @param _memecoin The memecoin to find the creator of
     *
     * @return The current creator of the memecoin
     */
    function _memecoinCreator(
        address _memecoin
    ) internal view virtual returns (address) {
        return IMemecoin(_memecoin).creator();
    }

    /**
     * Unwinds a pool's BidWall position, returning the liquidity to the {MemecoinTreasury}.
     *
     * @dev This is implemented by the inheriting {PositionManager}, as the closure requires a
     * {PoolManager} unlock that only the hook can open.
     *
     * @param _poolKey The PoolKey to close the BidWall of
     */
    function _closeBidWall(
        PoolKey memory _poolKey
    ) internal virtual;

    /**
     * Internally validates FeeDistribution structs to ensure they are valid.
     *
     * @dev If the struct is not valid, then the call will be reverted.
     *
     * @param _feeDistribution The FeeDistribution to be validated
     */
    function _validateFeeDistribution(
        FeeDistribution memory _feeDistribution
    ) internal pure {
        // Ensure our swap fee is below 100%
        if (_feeDistribution.swapFee > ONE_HUNDRED_PERCENT) {
            revert SwapFeeInvalid();
        }

        // Ensure our referrer fee is below 100%
        if (_feeDistribution.referrer > ONE_HUNDRED_PERCENT) {
            revert ReferrerFeeInvalid();
        }

        // Ensure our protocol fee is below 10%
        if (_feeDistribution.protocol > MAX_PROTOCOL_ALLOCATION) {
            revert ProtocolFeeInvalid();
        }
    }

    /**
     * Allows an owner to update the {IFeeCalculator} used to determine the swap fee.
     *
     * @param _feeCalculator The new {IFeeCalculator} to use
     */
    function setFeeCalculator(
        IFeeCalculator _feeCalculator
    ) public onlyOwner {
        feeCalculator = _feeCalculator;
        emit FeeCalculatorUpdated(address(_feeCalculator));
    }

    /**
     * Gets the distribution for a pool by checking to see if a pool has it's own FeeDistribution. If
     * it does then this is used, but if it isn't then it will fallback on the global FeeDistribution.
     *
     * @param _poolId The PoolId being updated
     *
     * @return feeDistribution_ The FeeDistribution applied to the pool
     */
    function getPoolFeeDistribution(
        PoolId _poolId
    ) public view returns (FeeDistribution memory feeDistribution_) {
        feeDistribution_ = (poolFeeDistribution[_poolId].active) ? poolFeeDistribution[_poolId] : feeDistribution;
    }

    /**
     * Hands the pool's flaunch parameters to the configured {IFeeCalculator} so it can record
     * any per-pool state it needs. The calculator is responsible for whatever per-pool
     * configuration it wants to derive from `_feeCalculatorParams`.
     *
     * @param _poolId The PoolId being updated
     * @param _feeCalculatorParams The parameters to pass to the fee calculator
     */
    function _initializeFeeCalculators(
        PoolId _poolId,
        bytes calldata _feeCalculatorParams
    ) internal {
        IFeeCalculator calculator = feeCalculator;
        if (address(calculator) != address(0)) {
            calculator.setFlaunchParams(_poolId, _feeCalculatorParams);
        }
    }

    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     */
    receive() external payable {}
}
