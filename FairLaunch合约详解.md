# FairLaunch.sol 合约详解

## 📚 目录

1. [Uniswap V3/V4 Position 概念基础](#uniswap-v3v4-position-概念基础)
2. [FairLaunch 核心思想](#fairlaunch-核心思想)
3. [合约结构解析](#合约结构解析)
4. [核心函数详解](#核心函数详解)
5. [公平启动完整流程](#公平启动完整流程)
6. [关键机制深入理解](#关键机制深入理解)
7. [代码示例与图解](#代码示例与图解)

---

## Uniswap V3/V4 Position 概念基础

### 什么是 Position（位置）？

在 Uniswap V3/V4 中，**Position（位置）** 是流动性提供者（LP）在特定价格区间内提供的流动性。

#### 核心概念

1. **Tick（刻度）**
   - Tick 是价格的离散化表示
   - 每个 tick 对应一个特定的价格
   - 价格 = 1.0001^tick
   - Tick 必须是 `tickSpacing` 的倍数（在 ƒlaunch 中为 60）

2. **价格区间（Tick Range）**
   - 每个 Position 都有一个 `tickLower`（下界）和 `tickUpper`（上界）
   - 流动性只在这个价格区间内有效
   - 当价格超出这个区间时，流动性会完全转换为其中一种代币

3. **流动性（Liquidity）**
   - 流动性是一个抽象概念，表示在价格区间内可用的交易深度
   - 流动性越多，价格滑点越小
   - 流动性可以转换为代币数量，反之亦然

#### Position 的数据结构

```solidity
// Uniswap V4 中的 Position 状态
struct State {
    uint128 liquidity;              // 该位置拥有的流动性数量
    uint256 feeGrowthInside0LastX128;  // 代币0的费用增长率
    uint256 feeGrowthInside1LastX128;  // 代币1的费用增长率
}
```

#### 单边流动性 vs 双边流动性

**双边流动性（正常情况）**：
- 同时提供两种代币（如 ETH 和 Token）
- 价格在区间内时，两种代币都会被使用
- 价格超出区间时，完全转换为一种代币

**单边流动性（FairLaunch 使用）**：
- 只提供一种代币（只有 Token，没有 ETH）
- 在固定价格（单个 tick）下提供
- 用户只能用 ETH 购买 Token，不能反向操作

---

## FairLaunch 核心思想

### 公平启动的目标

1. **价格固定**：在启动期间，所有购买者以相同价格购买
2. **只能买入**：防止早期购买者立即卖出获利
3. **风险保护**：早期购买者可以以进入价格（减去 AMM 费用）退出

### 实现机制

FairLaunch 通过创建一个**单边流动性位置**来实现：

```
正常流动性池：
┌─────────────────────────────────┐
│  ETH  │  Token  │  价格区间      │
│  50%  │  50%    │  [tick1, tick2]│
└─────────────────────────────────┘

FairLaunch 单边位置：
┌─────────────────────────────────┐
│  ETH  │  Token  │  价格区间      │
│   0%  │  100%   │  [tick, tick] │ ← 固定价格
└─────────────────────────────────┘
```

### 关键时间点

```
时间轴：
│
├─ 代币创建
│  └─ createPosition() 创建单边位置
│
├─ 公平启动窗口开始 (startsAt)
│  └─ 用户只能买入，价格固定
│
├─ 公平启动窗口结束 (endsAt)
│  └─ closePosition() 转换为正常流动性池
│
└─ 正常交易阶段
   └─ 价格可以自由波动
```

---

## 合约结构解析

### 数据结构

#### FairLaunchInfo

```solidity
struct FairLaunchInfo {
    uint startsAt;        // 公平启动开始时间戳
    uint endsAt;          // 公平启动结束时间戳
    int24 initialTick;    // 初始价格 tick（固定价格）
    uint revenue;         // 累积的 ETH 收入
    uint supply;          // 剩余的代币供应量
    bool closed;          // 是否已关闭
}
```

**关键字段解释**：

- `initialTick`: 公平启动的固定价格 tick
- `revenue`: 从公平启动中累积的 ETH（用于后续创建流动性池）
- `supply`: 公平启动中剩余的代币数量（随着购买而减少）

### 存储映射

```solidity
mapping (PoolId _poolId => FairLaunchInfo _info) internal _fairLaunchInfo;
```

每个池（PoolId）对应一个 FairLaunchInfo，记录该池的公平启动状态。

---

## 核心函数详解

### 1. createPosition() - 创建公平启动位置

#### 函数签名

```solidity
function createPosition(
    PoolId _poolId,              // 池的唯一标识
    int24 _initialTick,          // 初始价格 tick（固定价格）
    uint _flaunchesAt,           // 启动时间戳
    uint _initialTokenFairLaunch, // 用于公平启动的代币数量
    uint _fairLaunchDuration      // 公平启动持续时间
) public virtual onlyPositionManager returns (FairLaunchInfo memory)
```

#### 功能说明

**这个函数并不实际创建 Uniswap 的流动性位置**，而是：

1. **记录状态**：在 `_fairLaunchInfo` 中记录公平启动的元数据
2. **设置时间窗口**：计算开始和结束时间
3. **初始化供应量**：设置可用于公平启动的代币数量

#### 代码解析

```solidity
// 如果没有初始代币，将持续时间设为 0
if (_initialTokenFairLaunch == 0) {
    _fairLaunchDuration = 0;
}

// 计算结束时间
uint endsAt = _flaunchesAt + _fairLaunchDuration;

// 创建 FairLaunchInfo 记录
_fairLaunchInfo[_poolId] = FairLaunchInfo({
    startsAt: _flaunchesAt,
    endsAt: endsAt,
    initialTick: _initialTick,        // 固定价格
    revenue: 0,                        // 初始收入为 0
    supply: _initialTokenFairLaunch,   // 初始供应量
    closed: false                      // 未关闭
});
```

#### 重要理解

**为什么叫 `createPosition` 但不创建实际位置？**

- 在公平启动期间，代币实际上**还没有存入 Uniswap 池**
- 代币存储在 `PositionManager` 合约中
- 只有在用户购买时，才通过 `fillFromPosition()` 从"虚拟位置"中提取代币
- 实际的 Uniswap 位置是在 `closePosition()` 时创建的

#### 流程图

```
createPosition() 调用
    ↓
检查参数有效性
    ↓
计算时间窗口 (startsAt, endsAt)
    ↓
在 _fairLaunchInfo 中记录状态
    ↓
发出 FairLaunchCreated 事件
    ↓
返回 FairLaunchInfo
```

---

### 2. fillFromPosition() - 从公平启动位置填充交换

#### 函数签名

```solidity
function fillFromPosition(
    PoolKey memory _poolKey,     // 池的键（包含两种代币信息）
    int _amountSpecified,         // 指定的数量（可为正或负）
    bool _nativeIsZero            // 原生代币是否为 currency0
) public onlyPositionManager returns (
    BeforeSwapDelta beforeSwapDelta_,
    BalanceDelta balanceDelta_,
    FairLaunchInfo memory fairLaunchInfo_
)
```

#### 功能说明

这是公平启动的**核心函数**，处理用户在公平启动期间的购买请求。

#### 关键逻辑：amountSpecified 的正负含义

在 Uniswap V4 中，`amountSpecified` 的正负表示不同的含义：

- **负数 (`amountSpecified < 0`)**：
  - 表示**输入代币的数量**（ETH 的数量）
  - 用户说："我想用 X ETH 购买代币"
  - 需要计算能获得多少代币

- **正数 (`amountSpecified > 0`)**：
  - 表示**输出代币的数量**（Token 的数量）
  - 用户说："我想购买 X 个代币"
  - 需要计算需要多少 ETH

#### 代码解析

```solidity
uint ethIn;
uint tokensOut;

// 情况 1: amountSpecified < 0 (用户指定 ETH 数量)
if (_amountSpecified < 0) {
    ethIn = uint(-_amountSpecified);  // ETH 输入量
    // 根据固定价格计算能获得多少代币
    tokensOut = _getQuoteAtTick(
        info.initialTick,  // 使用固定价格 tick
        ethIn,
        nativeToken,      // 基础代币（ETH）
        memecoin          // 报价代币（Token）
    );
}
// 情况 2: amountSpecified > 0 (用户指定 Token 数量)
else {
    tokensOut = uint(_amountSpecified);  // Token 输出量
    // 根据固定价格计算需要多少 ETH
    ethIn = _getQuoteAtTick(
        info.initialTick,  // 使用固定价格 tick
        tokensOut,
        memecoin,          // 基础代币（Token）
        nativeToken        // 报价代币（ETH）
    );
}
```

#### 供应量限制处理

```solidity
// 如果用户请求的代币超过可用供应量
if (tokensOut > info.supply) {
    // 按比例减少 ETH 输入
    uint percentage = info.supply * 1e18 / tokensOut;
    ethIn = (ethIn * percentage) / 1e18;
    
    // 限制代币输出为可用供应量
    tokensOut = info.supply;
}
```

#### 更新状态

```solidity
// 更新收入（累积 ETH）
info.revenue += ethIn;

// 减少供应量（代币被购买）
info.supply -= tokensOut;
```

#### 返回 Delta

```solidity
// BeforeSwapDelta: 告诉 Uniswap 我们已经处理了部分交换
beforeSwapDelta_ = (_amountSpecified < 0)
    ? toBeforeSwapDelta(ethIn.toInt128(), -tokensOut.toInt128())
    : toBeforeSwapDelta(-tokensOut.toInt128(), ethIn.toInt128());

// BalanceDelta: 实际的代币余额变化
balanceDelta_ = toBalanceDelta(
    _nativeIsZero ? ethIn.toInt128() : -tokensOut.toInt128(),
    _nativeIsZero ? -tokensOut.toInt128() : ethIn.toInt128()
);
```

#### 流程图

```
用户发起购买
    ↓
fillFromPosition() 被调用
    ↓
判断 amountSpecified 正负
    ├─ < 0: 指定 ETH，计算 Token
    └─ > 0: 指定 Token，计算 ETH
    ↓
使用 _getQuoteAtTick() 计算价格
    ↓
检查供应量限制
    ↓
更新 revenue 和 supply
    ↓
返回 BeforeSwapDelta 和 BalanceDelta
```

---

### 3. closePosition() - 关闭公平启动并创建流动性池

#### 函数签名

```solidity
function closePosition(
    PoolKey memory _poolKey,  // 池的键
    uint _tokenFees,          // 需要保留的代币手续费
    bool _nativeIsZero        // 原生代币是否为 currency0
) public onlyPositionManager returns (FairLaunchInfo memory)
```

#### 功能说明

当公平启动窗口结束时，这个函数：

1. **关闭公平启动状态**
2. **创建实际的 Uniswap 流动性位置**：
   - 使用累积的 ETH (`revenue`) 创建一个位置
   - 使用剩余的代币创建另一个位置
3. **标记为已关闭**

#### 关键逻辑：创建两个位置

公平启动结束后，需要创建**两个独立的流动性位置**：

##### 位置 1: ETH 位置（在初始价格上方）

```solidity
if (_nativeIsZero) {
    // ETH 是 currency0
    tickLower = (info.initialTick + 1).validTick(false);
    tickUpper = tickLower + TickFinder.TICK_SPACING;
    _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, true);
}
```

**位置说明**：
- 使用累积的 ETH (`revenue`)
- 位置在 `initialTick + 1` 到 `initialTick + 1 + TICK_SPACING`
- 这是一个**单边 ETH 位置**（只有 ETH，没有 Token）

##### 位置 2: Token 位置（在初始价格下方）

```solidity
if (_nativeIsZero) {
    // Token 是 currency1
    tickLower = TickFinder.MIN_TICK;
    tickUpper = (info.initialTick - 1).validTick(true);
    _createImmutablePosition(_poolKey, tickLower, tickUpper, 
        _poolKey.currency1.balanceOf(msg.sender) - _tokenFees - info.supply, 
        false);
}
```

**位置说明**：
- 使用剩余的代币（总代币 - 手续费 - 已售出代币）
- 位置从 `MIN_TICK` 到 `initialTick - 1`
- 这是一个**单边 Token 位置**（只有 Token，没有 ETH）

#### 为什么创建两个位置？

```
价格轴：
│
├─ MIN_TICK ──────────────────────────────── MAX_TICK
│
│  [Token 位置]  │  [ETH 位置]  │
│  (下方)       │  (上方)      │
│               │              │
│               └─ initialTick (公平启动价格)
│
```

**原因**：
1. **价格发现**：两个位置之间形成价格区间，允许价格波动
2. **流动性分布**：ETH 在上方提供买入支持，Token 在下方提供卖出支持
3. **平滑过渡**：从固定价格平滑过渡到动态价格

#### 代码解析

```solidity
// 获取公平启动信息
FairLaunchInfo storage info = _fairLaunchInfo[_poolKey.toId()];

int24 tickLower;
int24 tickUpper;

if (_nativeIsZero) {
    // 情况 1: ETH 是 currency0
    // 创建 ETH 位置（在初始价格上方）
    tickLower = (info.initialTick + 1).validTick(false);
    tickUpper = tickLower + TickFinder.TICK_SPACING;
    _createImmutablePosition(_poolKey, tickLower, tickUpper, info.revenue, true);
    
    // 创建 Token 位置（在初始价格下方）
    tickLower = TickFinder.MIN_TICK;
    tickUpper = (info.initialTick - 1).validTick(true);
    uint remainingTokens = _poolKey.currency1.balanceOf(msg.sender) 
                          - _tokenFees 
                          - info.supply;
    _createImmutablePosition(_poolKey, tickLower, tickUpper, remainingTokens, false);
} else {
    // 情况 2: Token 是 currency0（类似逻辑，但方向相反）
    // ...
}

// 标记为已关闭
info.endsAt = block.timestamp;
info.closed = true;
```

#### 流程图

```
公平启动窗口结束
    ↓
closePosition() 被调用
    ↓
获取 FairLaunchInfo
    ↓
创建 ETH 位置（上方）
    ├─ 使用累积的 revenue
    └─ tick: [initialTick+1, initialTick+1+60]
    ↓
创建 Token 位置（下方）
    ├─ 使用剩余代币
    └─ tick: [MIN_TICK, initialTick-1]
    ↓
标记为已关闭
    ↓
发出 FairLaunchEnded 事件
```

---

### 4. _createImmutablePosition() - 创建不可变位置

#### 函数签名

```solidity
function _createImmutablePosition(
    PoolKey memory _poolKey,  // 池的键
    int24 _tickLower,         // 下界 tick
    int24 _tickUpper,         // 上界 tick
    uint _tokens,             // 代币数量
    bool _tokenIsZero          // 代币是否为 currency0
) internal
```

#### 功能说明

这是**真正创建 Uniswap 流动性位置**的函数。

#### 代码解析

```solidity
// 步骤 1: 计算流动性
uint128 liquidityDelta = _tokenIsZero 
    ? LiquidityAmounts.getLiquidityForAmount0({
        sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
        sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
        amount0: _tokens
    })
    : LiquidityAmounts.getLiquidityForAmount1({
        sqrtPriceAX96: TickMath.getSqrtPriceAtTick(_tickLower),
        sqrtPriceBX96: TickMath.getSqrtPriceAtTick(_tickUpper),
        amount1: _tokens
    });

// 步骤 2: 如果没有流动性，直接返回
if (liquidityDelta == 0) return;

// 步骤 3: 调用 PoolManager 创建位置
(BalanceDelta delta,) = poolManager.modifyLiquidity({
    key: _poolKey,
    params: IPoolManager.ModifyLiquidityParams({
        tickLower: _tickLower,
        tickUpper: _tickUpper,
        liquidityDelta: liquidityDelta.toInt128(),
        salt: ''
    }),
    hookData: ''
});

// 步骤 4: 结算代币（将代币存入池中）
if (delta.amount0() < 0) {
    _poolKey.currency0.settle(poolManager, msg.sender, uint(-int(delta.amount0())), false);
}

if (delta.amount1() < 0) {
    _poolKey.currency1.settle(poolManager, msg.sender, uint(-int(delta.amount1())), false);
}
```

#### 关键理解

1. **流动性计算**：
   - 根据 tick 范围和代币数量计算所需的流动性
   - `getLiquidityForAmount0` 用于 currency0
   - `getLiquidityForAmount1` 用于 currency1

2. **modifyLiquidity**：
   - 这是 Uniswap V4 的核心函数
   - 在指定 tick 范围内添加流动性
   - 返回 `BalanceDelta`，表示需要存入的代币数量

3. **settle（结算）**：
   - 将代币从调用者转移到 PoolManager
   - `delta < 0` 表示池需要代币（调用者需要支付）

---

### 5. _getQuoteAtTick() - 价格计算

#### 函数签名

```solidity
function _getQuoteAtTick(
    int24 _tick,           // 价格 tick
    uint _baseAmount,      // 基础代币数量
    address _baseToken,     // 基础代币地址
    address _quoteToken     // 报价代币地址
) internal pure returns (uint quoteAmount_)
```

#### 功能说明

根据 tick 和代币数量，计算交换后能获得多少另一种代币。

#### 价格公式

在 Uniswap 中，价格关系为：

```
price = (sqrtPriceX96 / 2^96)^2
```

对于两个代币的交换：

```
如果 baseToken < quoteToken:
    quoteAmount = baseAmount * price

如果 baseToken > quoteToken:
    quoteAmount = baseAmount / price
```

#### 代码解析

```solidity
// 获取 tick 对应的 sqrtPriceX96
uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_tick);

// 计算价格比例
if (sqrtPriceX96 <= type(uint128).max) {
    // 使用 192 位精度
    uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
    quoteAmount_ = _baseToken < _quoteToken
        ? FullMath.mulDiv(ratioX192, _baseAmount, 1 << 192)
        : FullMath.mulDiv(1 << 192, _baseAmount, ratioX192);
} else {
    // 使用 128 位精度（防止溢出）
    uint ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    quoteAmount_ = _baseToken < _quoteToken
        ? FullMath.mulDiv(ratioX128, _baseAmount, 1 << 128)
        : FullMath.mulDiv(1 << 128, _baseAmount, ratioX128);
}
```

---

## 公平启动完整流程

### 阶段 1: 初始化

```
1. PositionManager.flaunch() 被调用
   ↓
2. Flaunch.flaunch() 创建 ERC20 和 ERC721
   ↓
3. PositionManager 初始化 Uniswap 池
   ↓
4. FairLaunch.createPosition() 记录公平启动状态
   ├─ 设置 startsAt, endsAt
   ├─ 记录 initialTick（固定价格）
   ├─ 设置 supply（可用代币数量）
   └─ revenue = 0
```

### 阶段 2: 公平启动期间

```
用户发起购买
   ↓
PositionManager.beforeSwap() 检测到公平启动窗口
   ↓
FairLaunch.fillFromPosition() 处理购买
   ├─ 根据固定价格计算交换
   ├─ 更新 revenue（累积 ETH）
   └─ 减少 supply（代币被购买）
   ↓
用户获得代币，ETH 被累积
```

### 阶段 3: 公平启动结束

```
公平启动窗口结束
   ↓
PositionManager.beforeSwap() 检测到窗口已结束
   ↓
FairLaunch.closePosition() 被调用
   ├─ 创建 ETH 位置（使用累积的 revenue）
   ├─ 创建 Token 位置（使用剩余代币）
   └─ 标记为已关闭
   ↓
转换为正常的 Uniswap 流动性池
```

### 阶段 4: 正常交易

```
价格可以自由波动
   ↓
用户可以进行买卖操作
   ↓
BidWall 等机制开始工作
```

---

## 关键机制深入理解

### 1. 为什么价格固定？

**实现方式**：
- 使用单个 tick (`initialTick`) 作为价格
- 在 `fillFromPosition()` 中，始终使用 `info.initialTick` 计算价格
- 不依赖池的实际价格

**效果**：
- 所有购买者以相同价格购买
- 价格不会因为购买量而波动

### 2. 为什么只能买入？

**实现方式**：
- 在 `PositionManager.beforeSwap()` 中检查
- 如果 `zeroForOne != nativeIsZero`，则 revert
- 这意味着只能进行 ETH → Token 的交换

**效果**：
- 防止早期购买者立即卖出
- 确保公平启动期间价格稳定

### 3. 单边流动性如何工作？

**正常流动性池**：
```
价格在区间内：
  ETH: 50% | Token: 50%
  
价格超出区间：
  ETH: 100% | Token: 0%  (或相反)
```

**FairLaunch 单边位置**：
```
公平启动期间：
  ETH: 0% | Token: 100%  (固定价格)
  
公平启动结束后：
  ETH 位置: ETH: 100% | Token: 0%  (上方)
  Token 位置: ETH: 0% | Token: 100%  (下方)
```

### 4. 代币存储机制

**公平启动期间**：
- 代币存储在 `PositionManager` 合约中
- 不在 Uniswap 池中
- 通过 `fillFromPosition()` 从合约中提取

**公平启动结束后**：
- 代币存入 Uniswap 池的流动性位置
- 成为池的一部分
- 可以正常交易

---

## 代码示例与图解

### 示例 1: 创建公平启动

```solidity
// 假设参数
initialTick = 0          // 价格 = 1.0001^0 = 1.0
initialTokenFairLaunch = 1_000_000 * 1e18  // 100万代币
fairLaunchDuration = 7 days

// createPosition() 执行后
FairLaunchInfo {
    startsAt: block.timestamp,
    endsAt: block.timestamp + 7 days,
    initialTick: 0,
    revenue: 0,
    supply: 1_000_000 * 1e18,
    closed: false
}
```

### 示例 2: 用户购买

```solidity
// 用户用 1 ETH 购买代币
amountSpecified = -1e18  // 负数表示 ETH 输入

// fillFromPosition() 计算
ethIn = 1e18
tokensOut = _getQuoteAtTick(0, 1e18, ETH, Token)
          = 1e18 * 1.0  // 假设价格为 1:1
          = 1e18

// 更新状态
revenue += 1e18          // 累积 1 ETH
supply -= 1e18          // 减少 1 代币
```

### 示例 3: 关闭位置

```solidity
// 假设公平启动结束后
revenue = 100 ETH        // 累积了 100 ETH
supply = 500_000 * 1e18 // 还剩 50万代币

// closePosition() 创建两个位置

// 位置 1: ETH 位置
tickLower = 1
tickUpper = 61
liquidity = getLiquidityForAmount0(100 ETH, tick 1-61)
_createImmutablePosition(..., 100 ETH, ...)

// 位置 2: Token 位置
tickLower = MIN_TICK
tickUpper = -1
liquidity = getLiquidityForAmount1(500_000 * 1e18, MIN_TICK to -1)
_createImmutablePosition(..., 500_000 * 1e18, ...)
```

### 可视化图解

```
公平启动期间（固定价格）：
┌─────────────────────────────────────┐
│  Price = 1.0 (tick = 0)             │
│                                       │
│  ETH: 0                              │
│  Token: 1,000,000                    │
│                                       │
│  用户购买 → ETH 累积，Token 减少      │
└─────────────────────────────────────┘

公平启动结束后（两个位置）：
┌─────────────────────────────────────┐
│  Price Range                         │
│                                       │
│  [Token 位置]                        │
│  MIN_TICK ──────── tick=-1           │
│                                       │
│  tick=0 (初始价格)                   │
│                                       │
│  tick=1 ──────── tick=61 [ETH 位置]  │
│                                       │
│  价格可以在这个范围内波动              │
└─────────────────────────────────────┘
```

---

## 总结

### 核心要点

1. **createPosition()** 不创建实际位置，只记录状态
2. **fillFromPosition()** 是公平启动的核心，处理所有购买
3. **closePosition()** 创建两个单边位置，实现价格发现
4. **单边流动性** 是实现固定价格的关键

### 设计优势

1. **公平性**：所有购买者以相同价格购买
2. **安全性**：早期购买者可以退出
3. **灵活性**：结束后平滑过渡到正常交易
4. **效率**：使用 Uniswap V4 的原生机制

### 学习建议

1. **理解 Uniswap V3/V4 基础**：Tick、流动性、位置概念
2. **跟踪完整流程**：从创建到结束的每一步
3. **理解单边流动性**：这是实现固定价格的关键
4. **实践调试**：运行测试，观察状态变化

---

**希望这份文档能帮助你深入理解 FairLaunch 的实现原理！** 🚀

