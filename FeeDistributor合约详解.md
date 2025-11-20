# FeeDistributor.sol 合约详解

## 📚 目录

1. [FeeDistributor 核心概念](#feedistributor-核心概念)
2. [设计思想与架构](#设计思想与架构)
3. [合约结构解析](#合约结构解析)
4. [核心函数详解](#核心函数详解)
5. [费用分配机制深入理解](#费用分配机制深入理解)
6. [完整工作流程](#完整工作流程)
7. [代码示例与图解](#代码示例与图解)

---

## FeeDistributor 核心概念

### 什么是 FeeDistributor？

**FeeDistributor** 是一个**抽象合约**，负责捕获和分配交易手续费给不同的角色。

### 核心功能

1. **捕获手续费**：从交易中提取手续费
2. **分配手续费**：按优先级分配给不同角色
3. **动态计算**：支持动态费用计算器
4. **费用豁免**：支持特定地址的费用豁免
5. **托管管理**：使用 Escrow 合约管理费用

### 费用接收者角色

1. **推荐人（Referrer）**：通过推荐链接带来交易的地址
2. **协议（Protocol）**：协议本身，用于运营和维护
3. **创建者（Creator）**：代币的创建者，获得持续收益
4. **BidWall**：价格保护机制，使用手续费创建买单
5. **金库（Treasury）**：代币持有者控制的资金库

---

## 设计思想与架构

### 级联分配（Waterfall）机制

费用分配采用**级联方式**，每个角色按顺序从剩余金额中提取自己的份额：

```
总手续费
    ↓
1. 提取 Swap Fee（基础费率）
    ↓
2. 分配 Referrer Fee（推荐人费用）
    ↓
3. 分配 Protocol Fee（协议费用）
    ↓
4. 分配 Creator Fee（创建者费用）
    ↓
5. 剩余给 BidWall（或 Treasury）
```

**关键特点**：
- 百分比**不需要总和为 100%**
- 每个角色从**剩余金额**中提取
- 最后剩余的部分给 BidWall

### 全局 vs 池级别配置

```solidity
// 全局配置（默认）
FeeDistribution internal feeDistribution;

// 池级别配置（覆盖全局）
mapping (PoolId _poolId => FeeDistribution _feeDistribution) internal poolFeeDistribution;
```

**优先级**：
1. 如果池有自定义配置（`active = true`），使用池配置
2. 否则，使用全局配置

### 费用计算器（FeeCalculator）

支持两种费用计算器：

1. **标准费用计算器**：正常交易时使用
2. **公平启动费用计算器**：公平启动期间使用

**作用**：
- 可以根据交易量、价格等动态调整费率
- 支持不同的费率策略（固定、动态、基于热度等）

---

## 合约结构解析

### 数据结构

#### FeeDistribution

```solidity
struct FeeDistribution {
    uint24 swapFee;      // 基础交换费率（从交易中提取的百分比）
    uint24 referrer;     // 推荐人费用百分比
    uint24 protocol;     // 协议费用百分比
    bool active;         // 是否激活（用于池级别配置）
}
```

**字段说明**：

- `swapFee`: 从交易金额中提取的费率（如 100 = 1%）
- `referrer`: 推荐人从手续费中获得的百分比
- `protocol`: 协议从手续费中获得的百分比
- `active`: 仅用于池级别配置，表示是否使用自定义配置

**注意**：
- 百分比使用基点（basis points），`100_00 = 100%`
- `swapFee` 是从交易金额中提取，其他是从手续费中分配

#### 存储映射

```solidity
// 全局费用分配配置
FeeDistribution internal feeDistribution;

// 池级别的费用分配配置（覆盖全局）
mapping (PoolId _poolId => FeeDistribution _feeDistribution) internal poolFeeDistribution;

// 创建者费用分配（由创建者设置）
mapping (PoolId _poolId => uint24 _creatorFee) internal creatorFee;
```

### 关键常量

```solidity
uint internal constant ONE_HUNDRED_PERCENT = 100_00;  // 100%
uint24 public constant MAX_PROTOCOL_ALLOCATION = 10_00;  // 10%（协议费用上限）
```

---

## 核心函数详解

### 1. _captureSwapFees() - 捕获交易手续费

#### 函数签名

```solidity
function _captureSwapFees(
    IPoolManager _poolManager,
    PoolKey calldata _key,
    IPoolManager.SwapParams memory _params,
    IFeeCalculator _feeCalculator,
    Currency _swapFeeCurrency,
    uint _swapAmount,
    FeeExemptions.FeeExemption memory _feeExemption
) internal returns (uint swapFee_)
```

#### 功能说明

这是**捕获手续费的核心函数**，从交易中提取手续费。

#### 执行流程

##### 步骤 1: 获取基础费率

```solidity
// 从池的 FeeDistribution 获取基础 swapFee
uint24 baseSwapFee = getPoolFeeDistribution(_key.toId()).swapFee;
```

##### 步骤 2: 应用费用计算器（如果存在）

```solidity
// 如果设置了费用计算器，使用它来动态计算费率
if (address(_feeCalculator) != address(0)) {
    baseSwapFee = _feeCalculator.determineSwapFee(_key, _params, baseSwapFee);
}
```

**费用计算器的作用**：
- 可以根据交易量、价格变化等动态调整费率
- 例如：大额交易费率更高，或基于价格波动调整

##### 步骤 3: 应用费用豁免（如果存在）

```solidity
// 如果用户有费用豁免，且豁免费率更低，使用豁免费率
if (_feeExemption.enabled && _feeExemption.flatFee < baseSwapFee) {
    baseSwapFee = _feeExemption.flatFee;
}
```

**费用豁免机制**：
- 某些地址（如白名单）可以享受更低的费率
- 只有在豁免费率更低时才生效

##### 步骤 4: 计算并提取手续费

```solidity
// 计算手续费金额
swapFee_ = _swapAmount * baseSwapFee / ONE_HUNDRED_PERCENT;

// 从 PoolManager 提取手续费
_poolManager.take(_swapFeeCurrency, address(this), swapFee_);
```

#### 完整流程图

```
用户发起交易
    ↓
_captureSwapFees() 被调用
    ↓
获取基础费率（从 FeeDistribution）
    ↓
应用费用计算器（如果存在）
    ↓
应用费用豁免（如果存在且更低）
    ↓
计算手续费金额
    ↓
从 PoolManager 提取手续费
    ↓
返回手续费金额
```

#### 示例

```solidity
// 假设参数
swapAmount = 100 ETH
baseSwapFee = 100 (1%)
feeCalculator 调整后 = 150 (1.5%)
feeExemption.flatFee = 50 (0.5%)

// 执行流程
baseSwapFee = 100
baseSwapFee = 150 (应用费用计算器)
baseSwapFee = 50 (应用费用豁免，因为 50 < 150)

swapFee = 100 ETH * 50 / 10000 = 0.5 ETH
```

---

### 2. _distributeReferrerFees() - 分配推荐人费用

#### 函数签名

```solidity
function _distributeReferrerFees(
    PoolKey calldata _key,
    Currency _swapFeeCurrency,
    uint _swapFee,
    bytes calldata _hookData
) internal returns (uint referrerFee_)
```

#### 功能说明

从手续费中提取推荐人的份额，并立即转移。

#### 执行流程

##### 步骤 1: 检查是否有推荐人

```solidity
// 检查 hookData 是否包含推荐人地址
if (_hookData.length == 0) {
    return referrerFee_;  // 没有推荐人
}

// 解码推荐人地址
(address referrer) = abi.decode(_hookData, (address));

if (referrer == address(0)) {
    return referrerFee_;  // 零地址，无效
}
```

##### 步骤 2: 检查推荐人费率

```solidity
// 获取推荐人费率（从池配置或全局配置）
uint24 referrerShare = getPoolFeeDistribution(poolId).referrer;

if (referrerShare == 0) {
    return referrerFee_;  // 没有设置推荐人费率
}
```

##### 步骤 3: 计算并分配推荐人费用

```solidity
// 计算推荐人费用（从总手续费中提取）
referrerFee_ = _swapFee * feeDistribution.referrer / ONE_HUNDRED_PERCENT;

// 分配方式
if (address(referralEscrow) == address(0)) {
    // 直接转账给推荐人
    _swapFeeCurrency.transfer(referrer, referrerFee_);
} else {
    // 转入 ReferralEscrow，推荐人可以稍后领取
    _swapFeeCurrency.transfer(address(referralEscrow), referrerFee_);
    referralEscrow.assignTokens(poolId, referrer, Currency.unwrap(_swapFeeCurrency), referrerFee_);
}
```

#### 关键理解

**为什么推荐人费用立即分配？**

- 推荐人费用是**即时奖励**，鼓励推荐
- 不需要累积到阈值
- 直接从手续费中提取，不参与后续分配

**ReferralEscrow vs 直接转账**：

- **直接转账**：推荐人立即收到
- **ReferralEscrow**：推荐人可以稍后领取，支持批量操作

#### 示例

```solidity
// 假设参数
swapFee = 1 ETH
referrerShare = 500 (5%)

// 计算
referrerFee = 1 ETH * 500 / 10000 = 0.05 ETH

// 分配
// 如果使用 ReferralEscrow：
referralEscrow.assignTokens(poolId, referrer, ETH, 0.05 ETH)
// 推荐人稍后可以领取
```

---

### 3. feeSplit() - 计算费用分配

#### 函数签名

```solidity
function feeSplit(PoolId _poolId, uint _amount) 
    public view returns (uint bidWall_, uint creator_, uint protocol_)
```

#### 功能说明

计算给定金额如何分配给协议、创建者和 BidWall。

#### 执行流程

```solidity
// 步骤 1: 获取池的 FeeDistribution
FeeDistribution memory _poolFeeDistribution = getPoolFeeDistribution(_poolId);

// 步骤 2: 提取协议费用
if (_poolFeeDistribution.protocol != 0) {
    protocol_ = _amount * _poolFeeDistribution.protocol / ONE_HUNDRED_PERCENT;
    _amount -= protocol_;  // 从剩余金额中扣除
}

// 步骤 3: 提取创建者费用
uint24 _creatorFee = creatorFee[_poolId];
if (_creatorFee != 0) {
    creator_ = _amount * _creatorFee / ONE_HUNDRED_PERCENT;
    _amount -= creator_;  // 从剩余金额中扣除
}

// 步骤 4: 剩余给 BidWall
bidWall_ = _amount;
```

#### 关键理解

**级联分配机制**：

```
总金额 = 1 ETH

协议费率 = 5% (500)
创建者费率 = 10% (1000)

分配：
1. 协议费用 = 1 ETH * 5% = 0.05 ETH
   剩余 = 1 - 0.05 = 0.95 ETH

2. 创建者费用 = 0.95 ETH * 10% = 0.095 ETH
   剩余 = 0.95 - 0.095 = 0.855 ETH

3. BidWall = 0.855 ETH（剩余全部）
```

**为什么是级联而不是独立计算？**

- 确保分配的总和不超过 100%
- 每个角色从剩余金额中提取，避免超额分配
- BidWall 获得剩余部分，保证所有资金都有去处

#### 示例

```solidity
// 假设配置
protocol = 5% (500)
creatorFee = 10% (1000)
amount = 1 ETH

// 执行
protocol_ = 1 ETH * 5% = 0.05 ETH
剩余 = 0.95 ETH

creator_ = 0.95 ETH * 10% = 0.095 ETH
剩余 = 0.855 ETH

bidWall_ = 0.855 ETH
```

---

### 4. _allocateFees() - 分配费用到托管

#### 函数签名

```solidity
function _allocateFees(PoolId _poolId, address _recipient, uint _amount) internal
```

#### 功能说明

将费用分配到 `FeeEscrow` 合约，供接收者稍后领取。

#### 执行流程

```solidity
// 步骤 1: 设置授权（如果需要）
if (IFLETH(nativeToken).allowance(msg.sender, address(feeEscrow)) < _amount) {
    IFLETH(nativeToken).approve(address(feeEscrow), type(uint).max);
}

// 步骤 2: 分配费用到托管
feeEscrow.allocateFees(_poolId, _recipient, _amount);
```

#### 关键理解

**为什么使用 FeeEscrow？**

1. **批量操作**：接收者可以一次性领取所有池的费用
2. **gas 效率**：避免每次交易都转账
3. **统一管理**：所有费用在一个地方管理

**FeeEscrow 的工作方式**：

```solidity
// FeeEscrow 内部
mapping (address _recipient => uint _amount) public balances;

function allocateFees(PoolId _poolId, address _recipient, uint _amount) external {
    balances[_recipient] += _amount;  // 累积余额
    IFLETH(nativeToken).transferFrom(msg.sender, address(this), _amount);
}

function withdrawFees(address _recipient, bool _unwrap) public {
    uint amount = balances[msg.sender];
    // 转账给接收者
}
```

---

### 5. getPoolFeeDistribution() - 获取池的费用配置

#### 函数签名

```solidity
function getPoolFeeDistribution(PoolId _poolId) 
    public view returns (FeeDistribution memory feeDistribution_)
```

#### 功能说明

获取池的费用配置，优先使用池级别配置，否则使用全局配置。

#### 执行逻辑

```solidity
feeDistribution_ = (poolFeeDistribution[_poolId].active) 
    ? poolFeeDistribution[_poolId]  // 使用池级别配置
    : feeDistribution;              // 使用全局配置
```

#### 关键理解

**配置优先级**：

```
检查池是否有自定义配置
    ├─ 有（active = true）→ 使用池配置
    └─ 无（active = false）→ 使用全局配置
```

**使用场景**：

- **全局配置**：适用于大多数池的默认费率
- **池级别配置**：特殊池可以设置不同的费率
  - 例如：某些池可以设置更高的协议费率
  - 或某些池可以设置更低的推荐人费率

---

### 6. getFeeCalculator() - 获取费用计算器

#### 函数签名

```solidity
function getFeeCalculator(bool _isFairLaunch) 
    public view returns (IFeeCalculator)
```

#### 功能说明

根据是否在公平启动期间，返回相应的费用计算器。

#### 执行逻辑

```solidity
// 如果在公平启动期间，且设置了公平启动费用计算器
if (_isFairLaunch && address(fairLaunchFeeCalculator) != address(0)) {
    return fairLaunchFeeCalculator;
}

// 否则返回标准费用计算器
return feeCalculator;
```

#### 关键理解

**为什么需要两个费用计算器？**

- **公平启动期间**：可能需要不同的费率策略
  - 例如：更低的费率鼓励交易
  - 或基于公平启动进度的动态费率
- **正常交易期间**：使用标准费率策略
  - 例如：基于交易量的动态费率
  - 或基于价格波动的费率

---

### 7. _initializeFeeCalculators() - 初始化费用计算器

#### 函数签名

```solidity
function _initializeFeeCalculators(PoolId _poolId, bytes calldata _feeCalculatorParams) internal
```

#### 功能说明

在代币启动时，初始化费用计算器的参数。

#### 执行流程

```solidity
// 步骤 1: 初始化公平启动费用计算器
IFeeCalculator fairLaunchCalculator = getFeeCalculator(true);
if (address(fairLaunchCalculator) != address(0)) {
    fairLaunchCalculator.setFlaunchParams(_poolId, _feeCalculatorParams);
}

// 步骤 2: 初始化标准费用计算器（如果不同）
IFeeCalculator standardCalculator = getFeeCalculator(false);
if (address(standardCalculator) != address(fairLaunchCalculator)) {
    standardCalculator.setFlaunchParams(_poolId, _feeCalculatorParams);
}
```

#### 关键理解

**为什么需要初始化？**

- 费用计算器可能需要池特定的参数
- 例如：初始价格、目标费率等
- 在代币启动时一次性设置，后续使用

---

## 费用分配机制深入理解

### 1. 费用分配优先级

完整的费用分配流程：

```
交易发生
    ↓
1. 捕获手续费（_captureSwapFees）
   ├─ 从交易金额中提取 swapFee
   └─ 返回手续费金额
    ↓
2. 分配推荐人费用（_distributeReferrerFees）
   ├─ 从手续费中提取推荐人份额
   └─ 立即转账给推荐人（或存入 ReferralEscrow）
    ↓
3. 存入剩余手续费（_depositFees）
   ├─ 存入 _poolFees[poolId]
   └─ 等待达到阈值
    ↓
4. 分配费用（_distributeFees，在 PositionManager 中）
   ├─ 检查是否达到阈值（0.001 ETH）
   ├─ 计算分配（feeSplit）
   │   ├─ Protocol Fee
   │   ├─ Creator Fee
   │   └─ BidWall Fee（剩余）
   └─ 分配给各个接收者
       ├─ Creator → FeeEscrow
       ├─ BidWall → BidWall.deposit()
       └─ Treasury → FeeEscrow（如果 BidWall 禁用）
```

### 2. 费用分配示例

#### 场景 1: 正常分配

```solidity
// 假设配置
swapFee = 1% (100)
referrer = 10% (1000)
protocol = 5% (500)
creatorFee = 10% (1000)

// 交易金额
swapAmount = 100 ETH

// 步骤 1: 捕获手续费
swapFee = 100 ETH * 1% = 1 ETH

// 步骤 2: 分配推荐人费用
referrerFee = 1 ETH * 10% = 0.1 ETH
剩余手续费 = 1 - 0.1 = 0.9 ETH

// 步骤 3: 存入剩余手续费
_poolFees[poolId] += 0.9 ETH

// 步骤 4: 达到阈值后分配
distributeAmount = 0.9 ETH

// feeSplit 计算
protocolFee = 0.9 ETH * 5% = 0.045 ETH
剩余 = 0.855 ETH

creatorFee = 0.855 ETH * 10% = 0.0855 ETH
剩余 = 0.7695 ETH

bidWallFee = 0.7695 ETH
```

#### 场景 2: 创建者销毁 NFT

```solidity
// 如果创建者销毁了 NFT
poolCreator = address(0)

// feeSplit 计算相同
protocolFee = 0.045 ETH
creatorFee = 0.0855 ETH
bidWallFee = 0.7695 ETH

// 但分配时
if (poolCreator == address(0)) {
    // 创建者费用转给 BidWall
    bidWallFee += creatorFee;  // 0.7695 + 0.0855 = 0.855 ETH
    creatorFee = 0;
}
```

#### 场景 3: BidWall 禁用

```solidity
// 如果 BidWall 被禁用
if (!bidWall.isBidWallEnabled(poolId)) {
    // BidWall 费用转给金库
    treasuryFee += bidWallFee;  // 0.7695 ETH
    bidWallFee = 0;
}
```

### 3. 费用计算器机制

#### 静态费率 vs 动态费率

**静态费率**：
```solidity
// 直接使用 FeeDistribution.swapFee
baseSwapFee = 100;  // 1%
```

**动态费率**（使用 FeeCalculator）：
```solidity
// 费用计算器可以根据条件调整费率
baseSwapFee = feeCalculator.determineSwapFee(_key, _params, baseSwapFee);

// 例如：
// - 大额交易：费率更高
// - 价格波动大：费率更高
// - 交易频率高：费率更低
```

#### 费用计算器接口

```solidity
interface IFeeCalculator {
    function determineSwapFee(
        PoolKey calldata _key,
        IPoolManager.SwapParams memory _params,
        uint24 _baseFee
    ) external returns (uint24);
    
    function setFlaunchParams(PoolId _poolId, bytes calldata _params) external;
}
```

### 4. 费用豁免机制

#### FeeExemption 结构

```solidity
struct FeeExemption {
    bool enabled;      // 是否启用豁免
    uint24 flatFee;    // 固定费率（如果更低则使用）
}
```

#### 豁免逻辑

```solidity
// 如果用户有豁免，且豁免费率更低
if (_feeExemption.enabled && _feeExemption.flatFee < baseSwapFee) {
    baseSwapFee = _feeExemption.flatFee;  // 使用豁免费率
}
```

**使用场景**：
- 白名单地址享受更低费率
- 合作伙伴享受优惠费率
- 特殊协议集成享受优惠

---

## 完整工作流程

### 场景 1: 正常交易流程

```
1. 用户发起交易
   ↓
2. PositionManager.beforeSwap()
   ├─ 处理 FairLaunch（如果在公平启动期间）
   └─ 处理 InternalSwapPool
   ↓
3. Uniswap V4 执行交换
   ↓
4. PositionManager.afterSwap()
   ├─ _captureAndDepositFees()
   │   ├─ _captureSwapFees()  ← 捕获手续费
   │   │   ├─ 获取基础费率
   │   │   ├─ 应用费用计算器
   │   │   ├─ 应用费用豁免
   │   │   └─ 提取手续费
   │   │
   │   ├─ _distributeReferrerFees()  ← 分配推荐人费用
   │   │   └─ 立即转账给推荐人
   │   │
   │   └─ _depositFees()  ← 存入剩余手续费
   │       └─ 存入 _poolFees[poolId]
   │
   └─ _distributeFees()  ← 分配累积的费用（如果达到阈值）
       ├─ 检查阈值（0.001 ETH）
       ├─ feeSplit() 计算分配
       └─ 分配给各个接收者
           ├─ Creator → FeeEscrow
           ├─ BidWall → BidWall.deposit()
           └─ Protocol → FeeEscrow
```

### 场景 2: 费用计算器调整费率

```
1. 用户发起大额交易
   ↓
2. _captureSwapFees()
   ├─ 基础费率 = 1%
   ├─ 费用计算器检测到大额交易
   │   └─ 调整费率 = 1.5%
   └─ 提取 1.5% 手续费
   ↓
3. 后续分配流程相同
```

### 场景 3: 推荐人获得费用

```
1. 用户在交易中包含推荐人地址（hookData）
   ↓
2. _distributeReferrerFees()
   ├─ 解码推荐人地址
   ├─ 计算推荐人费用（10%）
   └─ 转账给推荐人（或存入 ReferralEscrow）
   ↓
3. 剩余手续费继续正常分配
```

---

## 代码示例与图解

### 示例 1: 完整的费用分配

```solidity
// 假设配置
FeeDistribution {
    swapFee: 100,      // 1%
    referrer: 1000,    // 10%
    protocol: 500,     // 5%
    active: true
}
creatorFee: 1000       // 10%

// 交易
swapAmount = 100 ETH
referrer = 0x123... (在 hookData 中)

// 执行流程

// 1. 捕获手续费
swapFee = 100 ETH * 1% = 1 ETH

// 2. 分配推荐人费用
referrerFee = 1 ETH * 10% = 0.1 ETH
剩余 = 0.9 ETH

// 3. 存入剩余手续费
_poolFees[poolId] += 0.9 ETH

// 4. 达到阈值后分配（假设累积到 1 ETH）
distributeAmount = 1 ETH

// feeSplit 计算
protocolFee = 1 ETH * 5% = 0.05 ETH
剩余 = 0.95 ETH

creatorFee = 0.95 ETH * 10% = 0.095 ETH
剩余 = 0.855 ETH

bidWallFee = 0.855 ETH

// 分配
_allocateFees(poolId, creator, 0.095 ETH)  // 存入 FeeEscrow
bidWall.deposit(_poolKey, 0.855 ETH, ...)   // 存入 BidWall
_allocateFees(poolId, protocol, 0.05 ETH)   // 存入 FeeEscrow
```

### 示例 2: 费用计算器调整

```solidity
// 基础配置
baseSwapFee = 100  // 1%

// 费用计算器逻辑（伪代码）
function determineSwapFee(...) returns (uint24) {
    if (swapAmount > 10 ETH) {
        return 150;  // 大额交易，1.5%
    }
    return 100;  // 正常交易，1%
}

// 执行
swapAmount = 20 ETH
baseSwapFee = 100
baseSwapFee = 150  // 费用计算器调整
swapFee = 20 ETH * 1.5% = 0.3 ETH
```

### 示例 3: 费用豁免

```solidity
// 基础配置
baseSwapFee = 100  // 1%

// 用户费用豁免
feeExemption = {
    enabled: true,
    flatFee: 50  // 0.5%
}

// 执行
baseSwapFee = 100
// 应用费用计算器后 = 150
baseSwapFee = 50  // 应用豁免（50 < 150）
swapFee = 20 ETH * 0.5% = 0.1 ETH
```

### 可视化图解

#### 费用分配流程图

```
交易金额: 100 ETH
    ↓
提取手续费 (1%)
    ├─ 手续费: 1 ETH
    └─ 用户收到: 99 ETH
    ↓
分配推荐人费用 (10%)
    ├─ 推荐人: 0.1 ETH
    └─ 剩余: 0.9 ETH
    ↓
存入费用池
    └─ _poolFees[poolId] += 0.9 ETH
    ↓
达到阈值后分配
    ├─ 协议 (5%): 0.05 ETH → FeeEscrow
    ├─ 创建者 (10%): 0.095 ETH → FeeEscrow
    └─ BidWall (剩余): 0.855 ETH → BidWall.deposit()
```

#### 级联分配示意图

```
总手续费: 1 ETH
    │
    ├─ 协议 (5%)
    │   └─ 0.05 ETH
    │
    ├─ 剩余: 0.95 ETH
    │   │
    │   ├─ 创建者 (10%)
    │   │   └─ 0.095 ETH
    │   │
    │   └─ 剩余: 0.855 ETH
    │       │
    │       └─ BidWall
    │           └─ 0.855 ETH（全部剩余）
```

---

## 总结

### 核心要点

1. **级联分配机制**：每个角色从剩余金额中提取，确保总和不超过 100%
2. **优先级明确**：推荐人 → 协议 → 创建者 → BidWall
3. **灵活配置**：支持全局和池级别配置
4. **动态费率**：支持费用计算器动态调整费率
5. **费用豁免**：支持特定地址享受更低费率

### 设计优势

1. **公平性**：明确的分配规则，避免争议
2. **灵活性**：支持多种配置和计算方式
3. **效率**：使用 Escrow 批量管理，节省 gas
4. **可扩展**：支持自定义费用计算器

### 学习建议

1. **理解级联机制**：这是费用分配的核心
2. **跟踪完整流程**：从捕获到分配的每一步
3. **理解配置优先级**：全局 vs 池级别
4. **理解费用计算器**：如何动态调整费率

---

**希望这份文档能帮助你深入理解 FeeDistributor 的实现原理！** 🚀

