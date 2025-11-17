# PositionManager.afterSwap Hook 功能梳理

## 📋 Hook 概述

`afterSwap` 是 Uniswap V4 的核心 hook，在每次 swap 执行**之后**被调用。它负责捕获费用、分发收益、跟踪数据，是整个协议收益分配的核心逻辑。

**函数签名：**
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

**关键代码位置：** `src/contracts/PositionManager.sol:646-712`

---

## 🔄 执行流程（6个阶段）

### 阶段 1️⃣：计算 Swap 金额并捕获费用 (663-669行)

**功能：** 确定从哪个货币收取费用，并捕获 Uniswap swap 产生的费用。

```solidity
// 确定我们将会从哪个货币中收取费用
(int128 amount0, int128 amount1) = (_delta.amount0(), _delta.amount1());
int128 swapAmount = _params.amountSpecified < 0 == _params.zeroForOne ? amount1 : amount0;

// 捕获交换费用，并分发推荐人的份额（如果设置）
uint swapFee = _captureAndDepositFees(_key, _params, _sender, swapAmount, _hookData);
```

**关键点：**
- 📊 **确定费用货币**：根据 swap 方向（`zeroForOne`）和金额符号（`amountSpecified`）确定从哪个货币收取费用
- 💰 **捕获费用**：调用 `_captureAndDepositFees` 捕获实际费用
- 🎯 **动态费用计算**：根据是否在公平启动窗口内使用不同的费用计算器

**费用计算逻辑：**
- 如果在公平启动窗口内：使用公平启动费用计算器
- 如果不在：使用标准费用计算器
- 考虑费用豁免（FeeExemption）机制

---

### 阶段 2️⃣：记录 Swap 数据到临时存储 (671-677行)

**功能：** 将 Uniswap swap 的金额和费用记录到临时存储，用于后续事件发出。

```solidity
// 增加我们的交换记录
assembly {
    tstore(TS_UNI_AMOUNT0, amount0)
    tstore(TS_UNI_AMOUNT1, amount1)
}

_captureDeltaSwapFee(_params, TS_UNI_FEE0, TS_UNI_FEE1, swapFee);
```

**关键点：**
- 💾 **临时存储**：使用 `tstore` 存储 swap 数据（仅在交易内有效）
- 📝 **记录费用**：分别记录 amount0/amount1 和 fee0/fee1
- 🔗 **关联数据**：与 `beforeSwap` 中记录的 FairLaunch 和 ISP 数据关联

**存储的数据：**
- `TS_UNI_AMOUNT0`: Uniswap swap 的 currency0 金额
- `TS_UNI_AMOUNT1`: Uniswap swap 的 currency1 金额
- `TS_UNI_FEE0`: Uniswap swap 的 currency0 费用
- `TS_UNI_FEE1`: Uniswap swap 的 currency1 费用

---

### 阶段 3️⃣：分发累积的费用 (685行)

**功能：** 如果累积的费用达到阈值，则分发到各个收益方。

```solidity
// 任何被交换转换的费用都需要分配
_distributeFees(_key);
```

**分发逻辑详解：**

#### 3.1 检查分发阈值
```solidity
uint distributeAmount = _poolFees[poolId].amount0;  // 获取原生代币（ETH）数量

// 确保累积的费用达到最小分发阈值
if (distributeAmount < MIN_DISTRIBUTE_THRESHOLD) return;  // 默认 0.001 ETH
```

#### 3.2 计算费用分配
```solidity
// 计算各个收益方的分配比例
(uint bidWallFee, uint creatorFee, uint protocolFee) = feeSplit(poolId, distributeAmount);
uint treasuryFee;
```

**费用分配方：**
- 🏦 **BidWall**: 流动性墙费用（用于提供流动性保护）
- 👤 **Creator**: 创建者费用（给 NFT 持有者）
- 💼 **Treasury**: 金库费用（给 MemecoinTreasury）
- 🏛️ **Protocol**: 协议费用（给协议方）

#### 3.3 分发到各个收益方

**创建者费用分发：**
```solidity
if (creatorFee != 0) {
    // 确保创建者没有销毁 NFT
    if (!poolCreatorBurned) {
        _allocateFees(poolId, poolCreator, creatorFee);
    } else {
        // 如果创建者销毁了 NFT，费用转给 BidWall
        bidWallFee += creatorFee;
    }
}
```

**BidWall 费用分发：**
```solidity
if (bidWallFee != 0) {
    // 尝试存入 BidWall
    if (bidWall.canImport(_poolKey, ...)) {
        bidWall.deposit(_poolKey, bidWallFee, _beforeSwapTick, nativeIsZero);
    } else {
        // 如果无法存入，转给 Treasury
        treasuryFee += bidWallFee;
    }
}
```

**Treasury 费用分发：**
```solidity
if (treasuryFee != 0) {
    // 确保创建者没有销毁 NFT
    if (!poolCreatorBurned) {
        _allocateFees(poolId, memecoin.treasury(), treasuryFee);
    } else {
        // 如果无法分配给 Treasury，转给协议
        protocolFee += treasuryFee;
    }
}
```

**协议费用分发：**
```solidity
if (protocolFee != 0) {
    _allocateFees(poolId, protocolFeeRecipient, protocolFee);
}
```

**关键代码位置：** `src/contracts/PositionManager.sol:968-1039`

---

### 阶段 4️⃣：跟踪 Swap 数据用于动态费用计算 (693-700行)

**功能：** 如果有费用计算器，跟踪 swap 数据用于未来的动态费用计算。

```solidity
PoolId poolId = _key.toId();

{
    IFeeCalculator _feeCalculator = getFeeCalculator(fairLaunch.inFairLaunchWindow(poolId));
    if (address(_feeCalculator) != address(0)) {
        _feeCalculator.trackSwap(_sender, _key, _params, _delta, _hookData);
    }
}
```

**关键点：**
- 📊 **动态费用**：根据历史 swap 数据动态调整费用
- 🎯 **不同计算器**：公平启动期间和正常期间使用不同的费用计算器
- 📈 **数据积累**：跟踪每次 swap 用于算法优化

**用途：**
- 根据交易量调整费用
- 根据价格波动调整费用
- 实现更复杂的费用模型（如时间加权、成交量加权等）

---

### 阶段 5️⃣：设置返回值并发出事件 (702-711行)

**功能：** 设置 hook 返回值，并发出 swap 更新事件和池状态更新事件。

```solidity
// 设置我们的返回选择器
hookDeltaUnspecified_ = swapFee.toInt128();

selector_ = IHooks.afterSwap.selector;

// 发出我们编译的交换数据
_emitSwapUpdate(poolId, _sender);

// 发出我们的池状态更新给监听者
_emitPoolStateUpdate(poolId, selector_, abi.encode(_sender, _params, _delta));
```

#### 5.1 Swap 更新事件

**`_emitSwapUpdate` 发出的事件：**

1. **PoolSwap 事件**（协议自定义）：
```solidity
emit PoolSwap(
    _poolId,
    _tload(TS_FL_AMOUNT0), _tload(TS_FL_AMOUNT1), _tload(TS_FL_FEE0), _tload(TS_FL_FEE1),
    _tload(TS_ISP_AMOUNT0), _tload(TS_ISP_AMOUNT1), _tload(TS_ISP_FEE0), _tload(TS_ISP_FEE1),
    _tload(TS_UNI_AMOUNT0), _tload(TS_UNI_AMOUNT1), _tload(TS_UNI_FEE0), _tload(TS_UNI_FEE1)
);
```

**包含的数据：**
- FairLaunch 阶段的金额和费用
- Internal Swap Pool 阶段的金额和费用
- Uniswap 阶段的金额和费用

2. **HookSwapEvent 事件**（Uniswap V4 标准化）：
```solidity
UniswapHookEvents.emitHookSwapEvent({
    _poolId: _poolId,
    _sender: _sender,
    _amount0: _tload(TS_FL_AMOUNT0) + _tload(TS_ISP_AMOUNT0),
    _amount1: _tload(TS_FL_AMOUNT1) + _tload(TS_ISP_AMOUNT1),
    _fee0: _tload(TS_FL_FEE0) + _tload(TS_ISP_FEE0),
    _fee1: _tload(TS_FL_FEE1) + _tload(TS_ISP_FEE1)
});
```

**关键代码位置：** `src/contracts/PositionManager.sol:1048-1085`

#### 5.2 池状态更新事件

**`_emitPoolStateUpdate` 发出的事件：**
- 包含池的当前状态（价格、tick、流动性等）
- 传递给订阅者（如前端、监控系统等）

---

## 📊 完整执行流程图

```
Uniswap V4 Swap 执行完成
    ↓
┌─────────────────────────────────────┐
│ [阶段1] 计算 Swap 金额并捕获费用     │
│  ├─ 确定费用货币                    │
│  ├─ 捕获费用（考虑豁免）            │
│  └─ 分发推荐人费用                  │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段2] 记录 Swap 数据               │
│  └─ 存储到临时存储（tstore）         │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段3] 分发累积的费用               │
│  ├─ 检查阈值（0.001 ETH）           │
│  ├─ 计算分配比例                    │
│  └─ 分发到各收益方                  │
│      ├─ Creator (如果未销毁 NFT)     │
│      ├─ BidWall (如果可以导入)      │
│      ├─ Treasury (如果未销毁 NFT)    │
│      └─ Protocol (最终兜底)          │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段4] 跟踪 Swap 数据               │
│  └─ 用于动态费用计算                 │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段5] 发出事件                     │
│  ├─ PoolSwap 事件                   │
│  ├─ HookSwapEvent 事件               │
│  └─ PoolStateUpdate 事件             │
└─────────────────────────────────────┘
    ↓
返回 hookDeltaUnspecified_ (费用金额)
```

---

## 🔑 核心辅助函数

### `_captureAndDepositFees`

**功能：** 捕获 swap 费用并存入费用池。

**流程：**
1. 确定费用货币（currency0 或 currency1）
2. 调用 `_captureSwapFees` 计算并捕获费用
3. 分发推荐人费用（如果有）
4. 将剩余费用存入 `_poolFees`（用于后续分发或 ISP 转换）

**关键代码位置：** `src/contracts/PositionManager.sol:913-956`

### `_distributeFees`

**功能：** 分发累积的费用到各个收益方。

**流程：**
1. 检查是否达到分发阈值（`MIN_DISTRIBUTE_THRESHOLD = 0.001 ETH`）
2. 计算各收益方的分配比例（`feeSplit`）
3. 按优先级分发：
   - Creator → BidWall（如果 Creator 销毁了 NFT）
   - BidWall → Treasury（如果无法导入 BidWall）
   - Treasury → Protocol（如果 Creator 销毁了 NFT）

**关键代码位置：** `src/contracts/PositionManager.sol:968-1039`

### `_allocateFees`

**功能：** 将费用分配到 `FeeEscrow` 合约，供用户后续领取。

**流程：**
1. 设置 `feeEscrow` 的授权
2. 调用 `feeEscrow.allocateFees` 分配费用

**关键代码位置：** `src/contracts/hooks/FeeDistributor.sol:148-156`

---

## 💰 费用分配机制

### 费用分配优先级

```
累积费用（达到阈值）
    ↓
1. Creator Fee（如果 NFT 未销毁）
    ↓ (如果销毁)
2. BidWall Fee（如果可以导入）
    ↓ (如果无法导入)
3. Treasury Fee（如果 NFT 未销毁）
    ↓ (如果销毁)
4. Protocol Fee（最终兜底）
```

### 费用分配比例

通过 `feeSplit` 函数计算，考虑：
- 创建者费用分配比例（`creatorFeeAllocation`）
- BidWall 是否启用
- 当前池状态

---

## 🎯 核心设计理念

### 1. **费用捕获与分配分离**
- 💰 立即捕获费用，但延迟分发
- 📊 累积到阈值再分发，减少 gas 成本
- 🔄 非 ETH 代币通过 ISP 转换为 ETH 后再分发

### 2. **灵活的收益分配**
- 🎯 根据状态动态调整分配（NFT 是否销毁、BidWall 是否可用）
- 🔄 自动降级机制（Creator → BidWall → Treasury → Protocol）
- 💼 通过 FeeEscrow 实现延迟领取

### 3. **数据跟踪与分析**
- 📈 跟踪每次 swap 用于动态费用计算
- 📊 发出详细事件供外部分析
- 🔍 支持复杂的费用模型

### 4. **推荐人机制**
- 👥 支持推荐人费用（通过 `_hookData` 传递）
- 💸 推荐人费用直接从 swap 费用中扣除
- 🎁 激励用户推广协议

---

## 📝 相关事件

### PoolSwap
```solidity
event PoolSwap(
    PoolId indexed poolId,
    int flAmount0, int flAmount1, int flFee0, int flFee1,
    int ispAmount0, int ispAmount1, int ispFee0, int ispFee1,
    int uniAmount0, int uniAmount1, int uniFee0, int uniFee1
);
```

### PoolFeesDistributed
```solidity
event PoolFeesDistributed(
    PoolId indexed _poolId,
    uint _donateAmount,
    uint _creatorAmount,
    uint _bidWallAmount,
    uint _governanceAmount,
    uint _protocolAmount
);
```

### PoolStateUpdated
```solidity
event PoolStateUpdated(
    PoolId indexed _poolId,
    uint160 _sqrtPriceX96,
    int24 _tick,
    uint24 _protocolFee,
    uint24 _swapFee,
    uint128 _liquidity
);
```

---

## 🔗 相关模块

- **FeeDistributor**: 费用分配逻辑
- **InternalSwapPool**: 费用代币转换
- **FeeEscrow**: 费用托管和领取
- **BidWall**: 流动性墙
- **FeeCalculator**: 动态费用计算

---

## 💡 设计亮点

1. **阈值分发**：累积到阈值再分发，优化 gas 成本
2. **自动降级**：费用分配有明确的降级路径，确保费用不会丢失
3. **延迟领取**：通过 FeeEscrow 实现费用延迟领取，提升用户体验
4. **数据驱动**：跟踪 swap 数据支持动态费用模型
5. **事件丰富**：发出详细事件便于外部分析和监控

---

## ⚠️ 注意事项

1. **分发阈值**：费用必须累积到 `MIN_DISTRIBUTE_THRESHOLD`（0.001 ETH）才会分发
2. **费用货币**：只有 ETH 等价物会被分发，其他代币通过 ISP 转换
3. **NFT 销毁影响**：如果创建者销毁了 NFT，Creator 和 Treasury 费用会转给其他收益方
4. **临时存储清理**：事件发出后会清理所有临时存储数据
5. **推荐人费用**：推荐人费用直接从 swap 费用中扣除，不参与后续分配

---

## 🔄 与 beforeSwap 的配合

`afterSwap` 与 `beforeSwap` 形成完整的 swap 生命周期：

```
beforeSwap
    ├─ 处理 FairLaunch
    ├─ 处理 Internal Swap Pool
    └─ 记录 FL 和 ISP 数据到临时存储
        ↓
Uniswap V4 Swap 执行
        ↓
afterSwap
    ├─ 捕获 Uniswap swap 费用
    ├─ 记录 Uniswap 数据到临时存储
    ├─ 分发累积费用
    ├─ 跟踪 swap 数据
    └─ 发出完整事件（包含 FL + ISP + UNI 数据）
```

**数据流：**
- `beforeSwap` 记录 FL 和 ISP 数据
- `afterSwap` 记录 UNI 数据
- `afterSwap` 发出包含所有三个阶段数据的完整事件

