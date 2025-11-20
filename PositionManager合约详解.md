# PositionManager.sol 合约详解

## 📚 目录

1. [PositionManager 核心概念](#positionmanager-核心概念)
2. [为什么 PositionManager 是核心？](#为什么-positionmanager-是核心)
3. [架构设计](#架构设计)
4. [核心功能模块](#核心功能模块)
5. [Uniswap V4 Hooks 详解](#uniswap-v4-hooks-详解)
6. [完整工作流程](#完整工作流程)
7. [费用处理机制](#费用处理机制)
8. [代码示例与图解](#代码示例与图解)

---

## PositionManager 核心概念

### 什么是 PositionManager？

**PositionManager** 是整个 flaunch 协议的**核心协调合约**，它是一个 **Uniswap V4 Hook**，控制着从代币创建、公平启动到持续交易的完整生命周期。

### 核心定位

1. **协议入口**：用户通过 PositionManager 创建和管理 Memecoin
2. **协调中心**：整合和协调所有子模块的交互
3. **Uniswap V4 Hook**：实现完整的 Hook 生命周期管理
4. **费用管理**：处理所有费用捕获、分配和分发

### 核心特点

```
PositionManager
    │
    ├─ 代币创建（flaunch）
    │   └─ 一站式创建 Memecoin 项目
    │
    ├─ Uniswap V4 Hooks
    │   ├─ beforeSwap / afterSwap
    │   ├─ beforeAddLiquidity / afterAddLiquidity
    │   └─ beforeRemoveLiquidity / afterRemoveLiquidity
    │
    ├─ 模块协调
    │   ├─ FairLaunch（公平启动）
    │   ├─ BidWall（流动性墙）
    │   ├─ FeeDistributor（费用分配）
    │   └─ InternalSwapPool（内部交换池）
    │
    └─ 状态管理
        ├─ 池状态跟踪
        ├─ 事件通知
        └─ 费用累积和分配
```

---

## 为什么 PositionManager 是核心？

### 1. 统一入口

**问题**：
- 协议包含多个模块（FairLaunch、BidWall、FeeDistributor 等）
- 用户需要与多个合约交互
- 状态管理分散

**解决方案**：
- PositionManager 作为统一入口
- 用户只需与 PositionManager 交互
- 内部协调所有模块

### 2. Uniswap V4 集成

**问题**：
- 需要在 Uniswap 交换前后添加业务逻辑
- 需要拦截和处理费用
- 需要控制流动性操作

**解决方案**：
- 实现完整的 Uniswap V4 Hook 接口
- 在关键节点插入业务逻辑
- 无缝集成 Uniswap V4

### 3. 模块协调

**问题**：
- 多个模块需要协同工作
- 模块间有依赖关系
- 需要统一的状态管理

**解决方案**：
- PositionManager 协调所有模块
- 统一的状态管理
- 清晰的模块边界

---

## 架构设计

### 继承关系

```solidity
contract PositionManager is 
    BaseHook,              // Uniswap V4 Hook 基础类
    FeeDistributor,        // 费用分配模块
    InternalSwapPool,      // 内部交换池模块
    StoreKeys              // 临时存储键管理
```

**设计理念**：
- **模块化设计**：通过继承将功能拆分为独立模块
- **职责分离**：每个模块负责特定功能
- **代码复用**：共享逻辑通过继承实现
- **可维护性**：清晰的模块边界便于维护和升级

### 核心依赖合约

```solidity
IFlaunch public flaunchContract;           // 代币创建合约
IInitialPrice public initialPrice;          // 初始价格计算器
BidWall public bidWall;                     // 流动性墙
FairLaunch public fairLaunch;               // 公平启动逻辑
TreasuryActionManager public actionManager; // 金库操作管理
FeeExemptions public feeExemptions;        // 费用豁免管理
Notifier public notifier;                   // 事件通知系统
```

### Hook 权限配置

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: true,  // 防止外部初始化
        afterInitialize: false,
        beforeAddLiquidity: true,    // [FairLaunch], [InternalSwapPool]
        afterAddLiquidity: true,     // [EventTracking]
        beforeRemoveLiquidity: true, // [FairLaunch], [InternalSwapPool]
        afterRemoveLiquidity: true, // [EventTracking]
        beforeSwap: true,            // [FairLaunch], [InternalSwapPool]
        afterSwap: true,             // [FeeDistributor], [BidWall], [EventTracking]
        beforeDonate: false,
        afterDonate: true,           // [EventTracking]
        beforeSwapReturnDelta: true, // [InternalSwapPool]
        afterSwapReturnDelta: true,  // [FeeDistributor]
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

**关键理解**：
- Hook 权限决定了合约必须部署到的地址
- 权限位：`1011 1111 0111 00` = `2FDC`
- 这确保了合约地址的唯一性和可验证性

---

## 核心功能模块

### 1. 代币创建模块（flaunch）

#### 函数签名

```solidity
function flaunch(FlaunchParams calldata _params) external payable returns (address memecoin_)
```

#### 功能说明

一站式创建 Memecoin 项目，包括代币、NFT、Treasury 和 Uniswap 池的初始化。

#### 执行流程详解

##### 步骤 1: 调用 Flaunch 合约创建代币

```solidity
(memecoin_, memecoinTreasury, tokenId) = flaunchContract.flaunch(_params);
```

**完成的操作**：
- 部署 Memecoin（ERC20）
- 部署 MemecoinTreasury
- 铸造 ERC721 NFT 给创建者
- 铸造初始供应量给 PositionManager

##### 步骤 2: 确定货币顺序

```solidity
bool currencyFlipped = nativeToken >= memecoin_;
```

**关键理解**：
- Uniswap V4 要求 `currency0 < currency1`（按地址排序）
- 确保池的唯一性和一致性

##### 步骤 3: 创建 PoolKey

```solidity
PoolKey memory _poolKey = PoolKey({
    currency0: Currency.wrap(!currencyFlipped ? nativeToken : memecoin_),
    currency1: Currency.wrap(currencyFlipped ? nativeToken : memecoin_),
    fee: 0,
    tickSpacing: 60,
    hooks: IHooks(address(this))
});
```

##### 步骤 4: 初始化 MemecoinTreasury

```solidity
MemecoinTreasury(memecoinTreasury).initialize(
    payable(address(this)),
    address(actionManager),
    nativeToken,
    _poolKey
);
```

##### 步骤 5: 设置创建者费用分配

```solidity
if (_params.creatorFeeAllocation != 0) {
    creatorFee[poolId] = _params.creatorFeeAllocation;
}
```

##### 步骤 6: 初始化费用计算器

```solidity
_initializeFeeCalculators(poolId, _params.feeCalculatorParams);
```

##### 步骤 7: 初始化 Uniswap 池

```solidity
int24 initialTick = poolManager.initialize(
    _poolKey,
    initialPrice.getSqrtPriceX96(msg.sender, currencyFlipped, _params.initialPriceParams)
);
```

**关键理解**：
- 使用 `IInitialPrice` 计算初始价格
- 初始化 Uniswap V4 池

##### 步骤 8: 处理预挖（Premine）

```solidity
if (_params.premineAmount != 0) {
    int premineAmount = _params.premineAmount.toInt256();
    assembly { tstore(poolId, premineAmount) }
}
```

**关键理解**：
- 使用 transient storage（tstore）存储预挖数量
- 在同一交易中允许创建者购买代币

##### 步骤 9: 创建 FairLaunch 位置

```solidity
IMemecoin(memecoin_).approve(address(fairLaunch), type(uint).max);

fairLaunch.createPosition({
    _poolId: poolId,
    _initialTick: initialTick,
    _flaunchesAt: _params.flaunchAt > block.timestamp ? _params.flaunchAt : block.timestamp,
    _initialTokenFairLaunch: _params.initialTokenFairLaunch,
    _fairLaunchDuration: _params.fairLaunchDuration
});
```

**关键理解**：
- 授权 FairLaunch 合约使用代币
- 创建公平启动位置（即使没有公平启动也需要调用）

##### 步骤 10: 处理调度启动

```solidity
if (_params.flaunchAt > block.timestamp) {
    flaunchesAt[poolId] = _params.flaunchAt;
    emit PoolScheduled(poolId, _params.flaunchAt);
} else {
    flaunchesAt[poolId] = block.timestamp;
}
```

##### 步骤 11: 处理启动费用

```solidity
uint flaunchFee = getFlaunchingFee(_params.initialPriceParams);

if (flaunchFee != 0) {
    if (msg.value < flaunchFee) {
        revert InsufficientFlaunchFee(msg.value, flaunchFee);
    }
    SafeTransferLib.safeTransferETH(protocolFeeRecipient, flaunchFee);
}

// 退还多余的 ETH
if (msg.value > flaunchFee) {
    SafeTransferLib.safeTransferETH(msg.sender, msg.value - flaunchFee);
}
```

#### 完整流程图

```
用户调用 flaunch(params)
    ↓
[1] 调用 Flaunch.flaunch() 创建代币
    ├─ 部署 Memecoin
    ├─ 部署 MemecoinTreasury
    ├─ 铸造 ERC721 NFT
    └─ 铸造初始供应量
    ↓
[2] 确定货币顺序（currencyFlipped）
    ↓
[3] 创建 PoolKey
    ↓
[4] 初始化 MemecoinTreasury
    ↓
[5] 设置创建者费用分配
    ↓
[6] 初始化费用计算器
    ↓
[7] 初始化 Uniswap 池
    └─ poolManager.initialize()
    ↓
[8] 处理预挖（如果设置）
    └─ tstore(poolId, premineAmount)
    ↓
[9] 创建 FairLaunch 位置
    └─ fairLaunch.createPosition()
    ↓
[10] 处理调度启动
    └─ flaunchesAt[poolId] = timestamp
    ↓
[11] 处理启动费用
    ├─ 支付费用
    └─ 退还多余 ETH
    ↓
[12] 发出事件
    └─ PoolCreated, PoolScheduled
```

---

### 2. beforeSwap Hook - 交换前处理

#### 函数签名

```solidity
function beforeSwap(
    address _sender,
    PoolKey calldata _key,
    IPoolManager.SwapParams memory _params,
    bytes calldata _hookData
) public override onlyPoolManager returns (
    bytes4 selector_,
    BeforeSwapDelta beforeSwapDelta_,
    uint24
)
```

#### 功能说明

在 Uniswap 执行交换之前，处理 FairLaunch、InternalSwapPool 和 BidWall 的逻辑。

#### 执行流程详解

##### 阶段 1: 调度和预挖检查

```solidity
PoolId poolId = _key.toId();
uint _flaunchesAt = flaunchesAt[poolId];

if (_flaunchesAt != 0) {
    int premineAmount = _tload(PoolId.unwrap(poolId));
    
    if (premineAmount != 0 && _params.amountSpecified == premineAmount) {
        // 预挖交易，允许通过
        emit PoolPremine(poolId, premineAmount);
    } else {
        // 检查是否已到启动时间
        if (_flaunchesAt > block.timestamp) {
            revert TokenNotFlaunched(_flaunchesAt);
        }
        // 清除调度时间戳
        delete flaunchesAt[poolId];
    }
}
```

**关键理解**：
- 如果代币被调度到未来启动，需要检查时间
- 预挖交易必须匹配预挖数量
- 使用 transient storage 存储预挖数量

##### 阶段 2: FairLaunch 处理

```solidity
FairLaunch.FairLaunchInfo memory fairLaunchInfo = fairLaunch.fairLaunchInfo(_key.toId());

if (!fairLaunchInfo.closed) {
    bool nativeIsZero = nativeToken == Currency.unwrap(_key.currency0);
    
    // 情况 1: 公平启动窗口已结束，但位置未关闭
    if (_tload(PoolId.unwrap(poolId)) == 0 && !fairLaunch.inFairLaunchWindow(poolId)) {
        uint unsoldSupply = fairLaunchInfo.supply;
        
        // 关闭公平启动位置
        fairLaunch.closePosition({
            _poolKey: _key,
            _tokenFees: _poolFees[poolId].amount1,
            _nativeIsZero: nativeIsZero
        });
        
        // 销毁未售出的代币
        if (unsoldSupply != 0) {
            (nativeIsZero ? _key.currency1 : _key.currency0).transfer(BURN_ADDRESS, unsoldSupply);
            emit FairLaunchBurn(poolId, unsoldSupply);
        }
    }
    // 情况 2: 仍在公平启动窗口内
    else {
        // 防止卖出代币
        if (nativeIsZero != _params.zeroForOne) {
            revert FairLaunch.CannotSellTokenDuringFairLaunch();
        }
        
        // 从公平启动位置填充交换
        BalanceDelta fairLaunchFillDelta;
        (beforeSwapDelta_, fairLaunchFillDelta, fairLaunchInfo) = fairLaunch.fillFromPosition(
            _key,
            _params.amountSpecified,
            nativeIsZero
        );
        
        // 结算代币
        _settleDelta(_key, fairLaunchFillDelta);
        
        // 捕获费用
        uint swapFee = _captureAndDepositFees(
            _key,
            _params,
            _sender,
            beforeSwapDelta_.getUnspecifiedDelta(),
            _hookData
        );
        
        // 更新 delta
        beforeSwapDelta_ = toBeforeSwapDelta(
            beforeSwapDelta_.getSpecifiedDelta(),
            beforeSwapDelta_.getUnspecifiedDelta() + swapFee.toInt128()
        );
        
        // 如果代币售罄，关闭位置
        if (fairLaunchInfo.supply == 0) {
            fairLaunch.closePosition({
                _poolKey: _key,
                _tokenFees: _poolFees[poolId].amount1,
                _nativeIsZero: nativeIsZero
            });
        }
    }
}
```

**关键理解**：
- 公平启动期间只能购买，不能卖出
- 从公平启动位置填充交换需求
- 捕获费用并更新收入
- 代币售罄时自动关闭位置

##### 阶段 3: 清理预挖数据

```solidity
PoolId poolId = _key.toId();
assembly {
    tstore(poolId, 0)  // 清除 transient storage
}
```

**关键理解**：
- 防止预挖在多个交换中重复触发
- 使用 transient storage（仅在一个交易内有效）

##### 阶段 4: InternalSwapPool 处理

```solidity
(uint tokenIn, uint tokenOut) = _internalSwap(
    poolManager,
    _key,
    _params,
    nativeToken == Currency.unwrap(_key.currency0)
);

if (tokenIn + tokenOut != 0) {
    // 创建内部交换的 delta
    BeforeSwapDelta internalBeforeSwapDelta = _params.amountSpecified >= 0
        ? toBeforeSwapDelta(-tokenOut.toInt128(), tokenIn.toInt128())
        : toBeforeSwapDelta(tokenIn.toInt128(), -tokenOut.toInt128());
    
    // 捕获内部交换的费用
    uint swapFee = _captureAndDepositFees(
        _key,
        _params,
        _sender,
        internalBeforeSwapDelta.getUnspecifiedDelta(),
        _hookData
    );
    
    // 更新 delta
    beforeSwapDelta_ = toBeforeSwapDelta(
        beforeSwapDelta_.getSpecifiedDelta() + internalBeforeSwapDelta.getSpecifiedDelta(),
        beforeSwapDelta_.getUnspecifiedDelta() + internalBeforeSwapDelta.getUnspecifiedDelta() + swapFee.toInt128()
    );
}
```

**关键理解**：
- 使用累积的费用代币前置填充交换
- 减少对主池的影响
- 捕获内部交换的费用

##### 阶段 5: 捕获当前 Tick

```solidity
(, _beforeSwapTick,,) = poolManager.getSlot0(_key.toId());
```

**关键理解**：
- 保存交换前的 tick，用于 afterSwap

##### 阶段 6: BidWall 状态检查

```solidity
bidWall.checkStalePosition({
    _poolKey: _key,
    _currentTick: _beforeSwapTick,
    _nativeIsZero: nativeToken == Currency.unwrap(_key.currency0)
});
```

**关键理解**：
- 检查 BidWall 是否变得陈旧
- 如果超过时间窗口，自动重新定位

---

### 3. afterSwap Hook - 交换后处理

#### 函数签名

```solidity
function afterSwap(
    address _sender,
    PoolKey calldata _key,
    IPoolManager.SwapParams calldata _params,
    BalanceDelta _delta,
    bytes calldata _hookData
) public override onlyPoolManager returns (
    bytes4 selector_,
    int128 hookDeltaUnspecified_
)
```

#### 功能说明

在 Uniswap 执行交换之后，捕获费用、分配费用、跟踪交换数据。

#### 执行流程详解

##### 步骤 1: 确定交换金额

```solidity
(int128 amount0, int128 amount1) = (_delta.amount0(), _delta.amount1());
int128 swapAmount = _params.amountSpecified < 0 == _params.zeroForOne ? amount1 : amount0;
```

##### 步骤 2: 捕获交换费用

```solidity
uint swapFee = _captureAndDepositFees(_key, _params, _sender, swapAmount, _hookData);
```

**关键理解**：
- 从交换中捕获手续费
- 分配推荐人费用
- 存入费用池

##### 步骤 3: 记录交换数据

```solidity
assembly {
    tstore(TS_UNI_AMOUNT0, amount0)
    tstore(TS_UNI_AMOUNT1, amount1)
}

_captureDeltaSwapFee(_params, TS_UNI_FEE0, TS_UNI_FEE1, swapFee);
```

**关键理解**：
- 使用 transient storage 记录交换数据
- 用于后续事件发出

##### 步骤 4: 分配费用

```solidity
_distributeFees(_key);
```

**关键理解**：
- 如果费用达到阈值，分配给各个接收者
- 包括创建者、BidWall、Treasury、协议

##### 步骤 5: 跟踪交换数据

```solidity
IFeeCalculator _feeCalculator = getFeeCalculator(fairLaunch.inFairLaunchWindow(poolId));
if (address(_feeCalculator) != address(0)) {
    _feeCalculator.trackSwap(_sender, _key, _params, _delta, _hookData);
}
```

**关键理解**：
- 如果设置了费用计算器，跟踪交换数据
- 用于动态费用计算

##### 步骤 6: 发出事件

```solidity
_emitSwapUpdate(poolId, _sender);
_emitPoolStateUpdate(poolId, selector_, abi.encode(_sender, _params, _delta));
```

---

### 4. 流动性管理 Hooks

#### beforeAddLiquidity / afterAddLiquidity

```solidity
function beforeAddLiquidity(...) public view override onlyPoolManager returns (bytes4 selector_) {
    // 防止在公平启动期间添加流动性
    _canModifyLiquidity(_key.toId(), _sender);
    selector_ = IHooks.beforeAddLiquidity.selector;
}

function afterAddLiquidity(...) external override onlyPoolManager returns (bytes4 selector_, BalanceDelta) {
    selector_ = IHooks.afterAddLiquidity.selector;
    // 发出池状态更新事件
    _emitPoolStateUpdate(_key.toId(), selector_, abi.encode(_sender, _delta, _feesAccrued));
}
```

**关键理解**：
- 公平启动期间禁止添加流动性（除了 BidWall 和 FairLaunch）
- 添加流动性后发出状态更新事件

#### beforeRemoveLiquidity / afterRemoveLiquidity

```solidity
function beforeRemoveLiquidity(...) public view override onlyPoolManager returns (bytes4 selector_) {
    // 防止在公平启动期间移除流动性
    _canModifyLiquidity(_key.toId(), _sender);
    selector_ = IHooks.beforeRemoveLiquidity.selector;
}

function afterRemoveLiquidity(...) public override onlyPoolManager returns (bytes4 selector_, BalanceDelta) {
    selector_ = IHooks.afterRemoveLiquidity.selector;
    // 发出池状态更新事件
    _emitPoolStateUpdate(_key.toId(), selector_, abi.encode(_sender, _delta, _feesAccrued));
}
```

**关键理解**：
- 公平启动期间禁止移除流动性
- 移除流动性后发出状态更新事件

#### _canModifyLiquidity - 流动性修改权限检查

```solidity
function _canModifyLiquidity(PoolId _poolId, address _sender) internal view {
    // BidWall 和 FairLaunch 可以修改
    if (_sender == address(bidWall) || _sender == address(fairLaunch)) {
        return;
    }
    
    // 如果不在公平启动窗口，允许修改
    if (!fairLaunch.inFairLaunchWindow(_poolId)) {
        return;
    }
    
    // 其他情况禁止修改
    revert FairLaunch.CannotModifyLiquidityDuringFairLaunch();
}
```

---

## 费用处理机制

### 1. _captureAndDepositFees - 捕获和存入费用

#### 函数签名

```solidity
function _captureAndDepositFees(
    PoolKey calldata _key,
    IPoolManager.SwapParams memory _params,
    address _sender,
    int128 _delta,
    bytes calldata _hookData
) internal returns (uint swapFee_)
```

#### 执行流程

```solidity
// 1. 确定费用货币
Currency swapFeeCurrency = _params.amountSpecified < 0 == _params.zeroForOne 
    ? _key.currency1 
    : _key.currency0;

// 2. 捕获交换费用
swapFee_ = _captureSwapFees({
    _poolManager: poolManager,
    _key: _key,
    _params: _params,
    _feeCalculator: getFeeCalculator(fairLaunch.inFairLaunchWindow(_key.toId())),
    _swapFeeCurrency: swapFeeCurrency,
    _swapAmount: uint128(_delta < 0 ? -_delta : _delta),
    _feeExemption: feeExemptions.feeExemption(_sender)
});

// 3. 分配推荐人费用
uint referrerFee = _distributeReferrerFees({
    _key: _key,
    _swapFeeCurrency: swapFeeCurrency,
    _swapFee: swapFee_,
    _hookData: _hookData
});

// 4. 存入剩余费用
_depositFees(
    _key,
    Currency.unwrap(swapFeeCurrency) == nativeToken ? swapFee_ - referrerFee : 0,
    Currency.unwrap(swapFeeCurrency) == nativeToken ? 0 : swapFee_ - referrerFee
);
```

### 2. _distributeFees - 分配费用

#### 函数签名

```solidity
function _distributeFees(PoolKey memory _poolKey) internal
```

#### 执行流程

```solidity
PoolId poolId = _poolKey.toId();

// 1. 获取可分配金额
uint distributeAmount = _poolFees[poolId].amount0;

// 2. 检查阈值
if (distributeAmount < MIN_DISTRIBUTE_THRESHOLD) return;

// 3. 清空费用池
_poolFees[poolId].amount0 = 0;

// 4. 计算分配比例
(uint bidWallFee, uint creatorFee, uint protocolFee) = feeSplit(poolId, distributeAmount);
uint treasuryFee;

// 5. 检查创建者是否已销毁 NFT
IMemecoin memecoin = _poolKey.memecoin(nativeToken);
address poolCreator = memecoin.creator();
bool poolCreatorBurned = poolCreator == address(0);

// 6. 分配创建者费用
if (creatorFee != 0) {
    if (!poolCreatorBurned) {
        _allocateFees(poolId, poolCreator, creatorFee);
    } else {
        bidWallFee += creatorFee;  // 如果创建者销毁，给 BidWall
    }
}

// 7. 分配 BidWall 费用
if (bidWallFee != 0) {
    if (bidWall.isBidWallEnabled(poolId) && !fairLaunch.inFairLaunchWindow(poolId)) {
        bidWall.deposit(_poolKey, bidWallFee, _beforeSwapTick, nativeToken == Currency.unwrap(_poolKey.currency0));
    } else {
        treasuryFee += bidWallFee;  // 如果 BidWall 未启用，给 Treasury
    }
}

// 8. 分配 Treasury 费用
if (treasuryFee != 0) {
    if (!poolCreatorBurned) {
        _allocateFees(poolId, memecoin.treasury(), treasuryFee);
    } else {
        protocolFee += treasuryFee;  // 如果创建者销毁，给协议
    }
}

// 9. 分配协议费用
if (protocolFee != 0) {
    _allocateFees(poolId, protocolFeeRecipient, protocolFee);
}
```

**关键理解**：
- 费用分配采用级联机制
- 如果创建者销毁 NFT，费用重新分配
- 如果 BidWall 未启用，费用给 Treasury
- 如果 Treasury 无法接收，费用给协议

---

## 完整工作流程

### 场景 1: 创建新代币

```
用户调用 PositionManager.flaunch(params)
    ↓
[1] 调用 Flaunch.flaunch() 创建代币
    ├─ 部署 Memecoin
    ├─ 部署 MemecoinTreasury
    ├─ 铸造 ERC721 NFT
    └─ 铸造初始供应量
    ↓
[2] 创建 PoolKey 和初始化池
    ↓
[3] 创建 FairLaunch 位置
    ↓
[4] 处理预挖和调度
    ↓
完成！代币已启动
```

### 场景 2: 公平启动期间的交换

```
用户发起交换（购买代币）
    ↓
PositionManager.beforeSwap()
    ├─ [1] 检查调度和预挖
    ├─ [2] FairLaunch 处理
    │   ├─ 检查是否在窗口内
    │   ├─ 防止卖出
    │   ├─ fillFromPosition() 填充交换
    │   ├─ 捕获费用
    │   └─ 如果售罄，关闭位置
    ├─ [3] 清理预挖数据
    ├─ [4] InternalSwapPool 处理
    ├─ [5] 捕获当前 Tick
    └─ [6] BidWall 状态检查
    ↓
Uniswap V4 执行剩余交换
    ↓
PositionManager.afterSwap()
    ├─ [1] 捕获交换费用
    ├─ [2] 记录交换数据
    ├─ [3] 分配费用
    ├─ [4] 跟踪交换数据
    └─ [5] 发出事件
```

### 场景 3: 正常交易期间的交换

```
用户发起交换
    ↓
PositionManager.beforeSwap()
    ├─ [1] 检查调度（已清除）
    ├─ [2] FairLaunch 处理（已关闭）
    ├─ [3] InternalSwapPool 处理
    ├─ [4] 捕获当前 Tick
    └─ [5] BidWall 状态检查
    ↓
Uniswap V4 执行交换
    ↓
PositionManager.afterSwap()
    ├─ [1] 捕获交换费用
    ├─ [2] 记录交换数据
    ├─ [3] 分配费用
    │   ├─ 创建者费用
    │   ├─ BidWall 费用
    │   ├─ Treasury 费用
    │   └─ 协议费用
    ├─ [4] 跟踪交换数据
    └─ [5] 发出事件
```

---

## 代码示例与图解

### 示例 1: 创建新代币

```solidity
FlaunchParams memory params = FlaunchParams({
    creator: 0x111...,
    name: "My Memecoin",
    symbol: "MEME",
    tokenUri: "https://...",
    initialTokenFairLaunch: 1000000,
    fairLaunchDuration: 7 days,
    premineAmount: 10000,
    creatorFeeAllocation: 1000,  // 10%
    flaunchAt: block.timestamp,
    initialPriceParams: ...,
    feeCalculatorParams: ...
});

// 调用
address memecoin = positionManager.flaunch{value: 0.1 ether}(params);

// 结果
// - Memecoin 已部署
// - MemecoinTreasury 已部署
// - ERC721 NFT 已铸造给创建者
// - Uniswap 池已初始化
// - FairLaunch 位置已创建
```

### 示例 2: 公平启动期间的交换

```solidity
// 用户购买代币
poolManager.swap(
    poolKey,
    SwapParams({
        zeroForOne: true,  // ETH -> Token
        amountSpecified: 1 ether,
        sqrtPriceLimitX96: 0
    }),
    ""
);

// beforeSwap 处理
// 1. FairLaunch.fillFromPosition() 提供代币
// 2. 捕获费用
// 3. InternalSwapPool 可能提供部分代币

// afterSwap 处理
// 1. 捕获 Uniswap 交换费用
// 2. 分配费用
// 3. 发出事件
```

### 可视化图解

#### PositionManager 架构

```
PositionManager (核心协调器)
    │
    ├─ 继承模块
    │   ├─ BaseHook (Uniswap V4 Hook 基础)
    │   ├─ FeeDistributor (费用分配)
    │   ├─ InternalSwapPool (内部交换池)
    │   └─ StoreKeys (临时存储键)
    │
    ├─ 依赖合约
    │   ├─ Flaunch (代币创建)
    │   ├─ FairLaunch (公平启动)
    │   ├─ BidWall (流动性墙)
    │   ├─ FeeExemptions (费用豁免)
    │   └─ Notifier (事件通知)
    │
    └─ 核心功能
        ├─ flaunch() (创建代币)
        ├─ beforeSwap() (交换前处理)
        ├─ afterSwap() (交换后处理)
        └─ 流动性管理 Hooks
```

#### 交换流程

```
用户发起交换
    │
    ├─ beforeSwap()
    │   ├─ [SCHEDULE] 检查调度
    │   ├─ [FL] FairLaunch 处理
    │   │   ├─ 填充交换
    │   │   └─ 捕获费用
    │   ├─ [PREMINE] 清理数据
    │   ├─ [ISP] InternalSwapPool
    │   │   └─ 前置填充
    │   └─ [BW] BidWall 检查
    │
    ├─ Uniswap V4 执行交换
    │
    └─ afterSwap()
        ├─ [FD] 捕获费用
        ├─ [FD] 分配费用
        │   ├─ 创建者
        │   ├─ BidWall
        │   ├─ Treasury
        │   └─ 协议
        ├─ [FD] 跟踪数据
        └─ [Event] 发出事件
```

#### 费用分配流程

```
交换发生
    ↓
捕获费用
    ├─ 推荐人费用（立即分配）
    └─ 剩余费用（存入费用池）
    ↓
费用累积
    └─ _poolFees[poolId].amount0
    ↓
达到阈值（MIN_DISTRIBUTE_THRESHOLD）
    ↓
分配费用
    ├─ 创建者费用
    │   └─ 如果创建者销毁 → BidWall
    ├─ BidWall 费用
    │   └─ 如果未启用 → Treasury
    ├─ Treasury 费用
    │   └─ 如果无法接收 → 协议
    └─ 协议费用
```

---

## 关键机制深入理解

### 1. Transient Storage (tstore) 的使用

**为什么使用 tstore？**

1. **单交易内有效**：只在当前交易内有效，交易结束后自动清除
2. **Gas 优化**：比 storage 更省 gas
3. **防止重入**：自动清除，防止重入攻击

**使用场景**：
- 预挖数量存储
- 交换数据临时记录
- 费用数据临时记录

### 2. BeforeSwapDelta 的作用

**BeforeSwapDelta** 告诉 Uniswap 已经处理了多少交换：

```solidity
BeforeSwapDelta delta = toBeforeSwapDelta(
    specifiedDelta,    // 指定货币的 delta
    unspecifiedDelta   // 未指定货币的 delta
);
```

**关键理解**：
- 负数表示"已提供"（给用户）
- 正数表示"已消耗"（从用户）
- Uniswap 会根据这个 delta 调整后续交换

### 3. 费用分配的级联机制

**级联分配**确保所有费用都有去处：

```
总费用: 1 ETH
    ↓
协议 (5%): 0.05 ETH
剩余: 0.95 ETH
    ↓
创建者 (10%): 0.095 ETH（从 0.95 ETH 中提取）
剩余: 0.855 ETH
    ↓
BidWall: 0.855 ETH（剩余全部）
```

**优势**：
- 总和不超过 100%
- 所有资金都有去处
- 灵活的重新分配机制

### 4. 模块协调机制

**PositionManager 如何协调模块？**

1. **统一入口**：所有操作通过 PositionManager
2. **状态管理**：统一的状态跟踪
3. **事件通知**：统一的事件系统
4. **权限控制**：统一的权限管理

---

## 总结

### 核心要点

1. **协议协调中心**：整合所有模块，统一入口
2. **Uniswap V4 集成**：完整的 Hook 实现
3. **费用管理**：捕获、分配、分发费用
4. **状态管理**：统一的状态跟踪和事件通知

### 设计优势

1. **模块化**：清晰的模块边界
2. **可扩展**：易于添加新功能
3. **安全性**：严格的权限控制
4. **Gas 优化**：使用 transient storage

### 学习建议

1. **理解 Hook 机制**：Uniswap V4 Hook 的工作原理
2. **理解模块协调**：如何整合多个模块
3. **理解费用流程**：从捕获到分配的完整流程
4. **理解状态管理**：如何使用 transient storage

---

**希望这份文档能帮助你深入理解 PositionManager 的实现原理！** 🚀

