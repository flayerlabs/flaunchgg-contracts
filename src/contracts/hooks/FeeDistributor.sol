// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';
import {ReferralEscrow} from '@flaunch/escrows/ReferralEscrow.sol';
import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';

import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';


/**
 * This hook will allow our pools to have a range of fee distribution approaches. This will
 * fallback onto a global fee distribution if there is not a specific.
 * 这个钩子将允许我们的池具有各种费用分配方法。如果池没有特定的费用分配，则回退到全局费用分配。
 */
abstract contract FeeDistributor is Ownable {

    using MemecoinFinder for PoolKey;
    using PoolIdLibrary for PoolKey;

    error CallerNotCreator(address _caller);
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

    /// Emitted when our FairLaunch {FeeCalculator} contract is updated
    event FairLaunchFeeCalculatorUpdated(address _feeCalculator);

    /// Emitted when a pool's creator fee allocation is updated
    event CreatorFeeAllocationUpdated(PoolId indexed _poolId, uint24 _allocation);

    /// Emitted when a referrer fee has been paid out
    event ReferrerFeePaid(PoolId indexed _poolId, address _recipient, address _token, uint _amount);

    /// Emitted when the {ReferralEscrow} contract is updated
    event ReferralEscrowUpdated(address _referralEscrow);

    /**
     * Stores the percentages of fee distribution.
     * 存储费用分配的百分比。
     * @dev This works in a waterfall approach, with a percentage taking a share before
     * passing the potential allocation on to the next. This means that the percentages
     * listed don't need to equal 100%:
     * 这个工作在级联方法中，一个百分比在传递给下一个之前先拿走一部分。这意味着列出的百分比不需要等于100%：
     * `Fee priority: swapfee -> referrer -> protocol -> creator -> bidwall`
     * 费用优先级：交换费用 -> 推荐人 -> 协议 -> 创建者 -> BidWall
     *
     * @member swapFee The amount of the transaction taken as fee 交换费用的百分比
     * @member referrer The percentage that the referrer will receive 推荐人费用的百分比
     * @member protocol The percentage that the protocol will receive 协议费用的百分比
     * @member active If a FeeDistribution struct has been set for the mapping 如果一个FeeDistribution结构体被设置为映射
     */
    struct FeeDistribution {
        uint24 swapFee;
        uint24 referrer;
        uint24 protocol;
        bool active;
    }

    /// Helpful constant to define 100% to 2dp 帮助常量定义100%到2dp
    uint internal constant ONE_HUNDRED_PERCENT = 100_00;

    /// The maximum value of a protocol fee allocation 协议费用分配的最大值
    uint24 public constant MAX_PROTOCOL_ALLOCATION = 10_00;

    /// Maps the creators share of the fee distribution that can be set by the creator
    /// to reduce fees from hitting the bidwall. 映射创建者的费用分配，可以由创建者设置，以减少费用命中BidWall。
    mapping (PoolId _poolId => uint24 _creatorFee) internal creatorFee; 

    /// Maps individual pools to custom `FeeDistribution`s. These will overwrite the
    /// global `feeDistribution`. 映射单个池到自定义`FeeDistribution`s。这些将覆盖全局`feeDistribution`。
    mapping (PoolId _poolId => FeeDistribution _feeDistribution) internal poolFeeDistribution;

    /// Maps our IERC20 token addresses to their registered PoolKey 映射我们的IERC20代币地址到它们的注册PoolKey
    mapping (address _memecoin => PoolKey _poolKey) internal _poolKeys;

    /// The global FeeDistribution that will be applied to all pools 全局FeeDistribution，将应用于所有池
    FeeDistribution internal feeDistribution;

    /// The {ReferralEscrow} contract that will be used 将使用的{ReferralEscrow}合同
    ReferralEscrow public referralEscrow;

    /// The {FeeEscrow} contract that will be used 将使用的{FeeEscrow}合同
    FeeEscrow public feeEscrow;

    /// The {IFeeCalculator} used to calculate swap fees 将使用的{IFeeCalculator}合同，用于计算交换费用
    IFeeCalculator public feeCalculator;
    IFeeCalculator public fairLaunchFeeCalculator;

    /// Our internal native token   
    address public nativeToken;

    /// The address of the $FLAY token's governance  $FLAY代币治理的地址
    address public flayGovernance;

    /**
     * Set up our initial FeeDistribution data.
     * 设置我们的初始FeeDistribution数据。
     * @param _nativeToken Our internal native token
     * @param _feeDistribution The initial FeeDistribution value
     * @param _protocolOwner The initial EOA owner of the contract
     */
    constructor (address _nativeToken, FeeDistribution memory _feeDistribution, address _protocolOwner, address _flayGovernance, address _feeEscrow) {
        nativeToken = _nativeToken;

        // Set our initial fee distribution 设置我们的初始费用分配
        _validateFeeDistribution(_feeDistribution);
        feeDistribution = _feeDistribution;
        emit FeeDistributionUpdated(_feeDistribution);

        // Set our $FLAY token governance address
        flayGovernance = _flayGovernance;

        // Set our fee escrow 设置我们的费用托管
        feeEscrow = FeeEscrow(payable(_feeEscrow));

        // Grant ownership permissions to the caller 授予调用者所有权权限
        if (owner() == address(0)) {
            _initializeOwner(_protocolOwner);
        }
    }

    /**
     * Allows a deposit to be made against a user. The amount is stored within the
     * {FeeEscrow} contract to be claimed later.
     * 允许对用户进行存款。金额存储在{FeeEscrow}合同中，稍后可以提取。
     * @param _poolId The PoolId that the deposit came from
     * @param _recipient The recipient of the transferred token
     * @param _amount The amount of the token to be transferred
     */
    function _allocateFees(PoolId _poolId, address _recipient, uint _amount) internal {
        // set allowance so that `feeEscrow` can pull the fees 设置允许，以便`feeEscrow`可以提取费用
        if (IFLETH(nativeToken).allowance(msg.sender, address(feeEscrow)) < _amount) {
            IFLETH(nativeToken).approve(address(feeEscrow), type(uint).max);
        }

        // allocate the fees in the escrow 在托管中分配费用
        feeEscrow.allocateFees(_poolId, _recipient, _amount);
    }

    /**
     * Captures fees following a swap.
     * 捕获交换后的费用。
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
        IPoolManager.SwapParams memory _params,
        IFeeCalculator _feeCalculator,
        Currency _swapFeeCurrency,
        uint _swapAmount,
        FeeExemptions.FeeExemption memory _feeExemption
    ) internal returns (
        uint swapFee_
    ) {
        // If we have an empty swapAmount then we can exit early 如果我们没有交换金额，则可以提前退出
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
     * 检查是否在hookData中设置了推荐人，并直接将他们的份额转移到他们。当交换发生时调用，返回移除推荐人费用后的新费用金额。
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
        referrerFee_ = _swapFee * feeDistribution.referrer / ONE_HUNDRED_PERCENT;

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
     * 根据一个金额，显示每个不同接收者将收到的份额。
     * @dev Fee priority: swapfee -> referrer -> || protocol -> creator -> bidwall ||
     * 费用优先级：交换费用 -> 推荐人 -> || 协议 -> 创建者 -> BidWall ||
     * @param _poolId The PoolId that is having the fee split calculated
     * @param _amount The amount of token being passed in
     *
     * @return bidWall_ The amount that the PBW will receive
     * @return creator_ The amount that the token creator will receive
     * @return protocol_ The amount that the protocol will receive
     */
    function feeSplit(PoolId _poolId, uint _amount) public view returns (uint bidWall_, uint creator_, uint protocol_) {
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
     * 更新将存储推荐人费用的{ReferralEscrow}合同。
     * @param _referralEscrow The new {ReferralEscrow} contract address
     */
    function setReferralEscrow(address payable _referralEscrow) public onlyOwner {
        // Update our {ReferralEscrow} address
        referralEscrow = ReferralEscrow(_referralEscrow);
        emit ReferralEscrowUpdated(_referralEscrow);
    }

    /**
     * Allows the governing contract to make global changes to the fees.
     * 允许治理合同对费用进行全局更改。
     * @param _feeDistribution The new FeeDistribution value
     */
    function setFeeDistribution(FeeDistribution memory _feeDistribution) public onlyOwner {
        _validateFeeDistribution(_feeDistribution);

        // Update our FeeDistribution struct
        feeDistribution = _feeDistribution;
        emit FeeDistributionUpdated(_feeDistribution);
    }

    /**
     * Allows the $FLAY token governance to set the global protocol fee.
     * 允许$FLAY代币治理设置全局协议费用。
     * @param _protocol New protocol fee
     */
    function setProtocolFeeDistribution(uint24 _protocol) public {
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
     * 允许治理合同对池特定费用进行更改。
     * @param _poolId The PoolId being updated
     * @param _feeDistribution The new FeeDistribution value
     */
    function setPoolFeeDistribution(PoolId _poolId, FeeDistribution memory _feeDistribution) public onlyOwner {
        _validateFeeDistribution(_feeDistribution);

        // Update our FeeDistribution struct
        poolFeeDistribution[_poolId] = _feeDistribution;
        emit PoolFeeDistributionUpdated(_poolId, _feeDistribution);
    }

    /**
     * Internally validates FeeDistribution structs to ensure they are valid.
     * 内部验证FeeDistribution结构体以确保它们有效。
     * @dev If the struct is not valid, then the call will be reverted.
     * 如果结构体无效，则调用将被还原。
     * @param _feeDistribution The FeeDistribution to be validated
     */
    function _validateFeeDistribution(FeeDistribution memory _feeDistribution) internal pure {
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
     * 允许所有者更新用于确定交换费用的{IFeeCalculator}。
     * @param _feeCalculator The new {IFeeCalculator} to use
     */
    function setFeeCalculator(IFeeCalculator _feeCalculator) public onlyOwner {
        feeCalculator = _feeCalculator;
        emit FeeCalculatorUpdated(address(_feeCalculator));
    }

    /**
     * Allows an owner to update the {IFeeCalculator} used during FairLaunch to determine the
     * swap fee.
     * 允许所有者更新用于在FairLaunch期间确定交换费用的{IFeeCalculator}。
     * @param _feeCalculator The new {IFeeCalculator} to use
     */
    function setFairLaunchFeeCalculator(IFeeCalculator _feeCalculator) public onlyOwner {
        fairLaunchFeeCalculator = _feeCalculator;
        emit FairLaunchFeeCalculatorUpdated(address(_feeCalculator));
    }

    /**
     * Gets the distribution for a pool by checking to see if a pool has it's own FeeDistribution. If
     * it does then this is used, but if it isn't then it will fallback on the global FeeDistribution.
     * 获取池的分配，通过检查池是否有自己的FeeDistribution。如果有，则使用，如果没有，则回退到全局FeeDistribution。
     * @param _poolId The PoolId being updated
     *
     * @return feeDistribution_ The FeeDistribution applied to the pool
     */
    function getPoolFeeDistribution(PoolId _poolId) public view returns (FeeDistribution memory feeDistribution_) {
        feeDistribution_ = (poolFeeDistribution[_poolId].active) ? poolFeeDistribution[_poolId] : feeDistribution;
    }

    /**
     * Gets the {IFeeCalculator} contract that should be used based on which are set, and if the
     * pool is currently in FairLaunch or not.
     * 获取应该使用的{IFeeCalculator}合同，基于哪个被设置，以及池当前是否在FairLaunch。
     * @dev This could return a zero address if no fee calculators have been set
     * 如果没有任何费用计算器被设置，则可能返回一个零地址。
     * @param _isFairLaunch If the pool is currently in FairLaunch
     * 如果池当前在FairLaunch
     * @return IFeeCalculator The IFeeCalculator to use
     */
    function getFeeCalculator(bool _isFairLaunch) public view returns (IFeeCalculator) {
        if (_isFairLaunch && address(fairLaunchFeeCalculator) != address(0)) {
            return fairLaunchFeeCalculator;
        }

        return feeCalculator;
    }

    /**
     * Initializes both the Fair Launch and Standard {IFeeCalculator} flaunching parameters for a pool.
     * 初始化池的公平启动和标准{IFeeCalculator} flaunching参数。
     * @param _poolId The PoolId being updated
     * @param _feeCalculatorParams The parameters to pass to the fee calculators
     */
    function _initializeFeeCalculators(PoolId _poolId, bytes calldata _feeCalculatorParams) internal {
        // Check if we have a fair launch calculator assigned. If we do, then we want to register
        // any custom parameters that have been passed.
        IFeeCalculator fairLaunchCalculator = getFeeCalculator(true);
        if (address(fairLaunchCalculator) != address(0)) {
            fairLaunchCalculator.setFlaunchParams(_poolId, _feeCalculatorParams);
        }

        // Check if we have a standard calculator assigned that is different to the fair launch
        // calculator. If we do, then we want to register any custom parameters that have been
        // passed.
        IFeeCalculator standardCalculator = getFeeCalculator(false);
        if (address(standardCalculator) != address(fairLaunchCalculator)) {
            standardCalculator.setFlaunchParams(_poolId, _feeCalculatorParams);
        }
    }


    /**
     * Allows the contract to receive ETH when withdrawn from the flETH token.
     * 允许合同接收ETH，当从flETH代币中提取时。
     */
    receive () external payable {}

}
