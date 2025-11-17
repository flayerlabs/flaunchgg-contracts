# PositionManager.beforeSwap Hook 功能梳理

## 📋 Hook 概述

`beforeSwap` 是 Uniswap V4 的核心 hook，在每次 swap 执行**之前**被调用。它是 Flaunch 协议的核心逻辑，负责处理公平启动、费用优化、跨链桥接等多个关键流程。

**函数签名：**
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

**关键代码位置：** `src/contracts/PositionManager.sol:425-628`

---

## 🔄 执行流程（5个阶段）

### 阶段 1️⃣：调度与预挖验证 (441-467行)

**功能：** 检查 token 是否被安排在未来的某个时间点启动，并验证预挖请求。

```solidity
// 检查是否有调度时间戳
if (_flaunchesAt != 0) {
    // 检查是否有有效的预挖请求
    int premineAmount = _tload(PoolId.unwrap(poolId));
    if (premineAmount != 0 && _params.amountSpecified == premineAmount) {
        // ✅ 允许预挖交易通过
        emit PoolPremine(poolId, premineAmount);
    } else {
        // ❌ 如果还没到启动时间，拒绝交易
        if (_flaunchesAt > block.timestamp) {
            revert TokenNotFlaunched(_flaunchesAt);
        }
        // 启动时间已到，清除调度标记
        delete flaunchesAt[poolId];
    }
}
```

**关键点：**
- ✅ **预挖验证**：必须在同一区块 + 金额完全匹配
- ❌ **时间保护**：未到启动时间直接 revert
- 🧹 **自动清理**：启动时间到达后清除调度标记

---

### 阶段 2️⃣：公平启动（FairLaunch）处理 (469-558行)

这是 hook 的**核心逻辑**，处理两种场景：

#### 场景 A：公平启动窗口已结束，但位置未关闭 (481-497行)

```solidity
if (_tload(PoolId.unwrap(poolId)) == 0 && !fairLaunch.inFairLaunchWindow(poolId)) {
    uint unsoldSupply = fairLaunchInfo.supply;
    
    // 关闭公平启动位置，将剩余代币放入流动性池
    fairLaunch.closePosition({
        _poolKey: _key,
        _tokenFees: _poolFees[poolId].amount1,
        _nativeIsZero: nativeIsZero
    });
    
    // 销毁未售出的公平启动供应量
    if (unsoldSupply != 0) {
        (nativeIsZero ? _key.currency1 : _key.currency0).transfer(BURN_ADDRESS, unsoldSupply);
        emit FairLaunchBurn(poolId, unsoldSupply);
    }
}
```

**功能：**
- 🔒 自动关闭公平启动位置
- 💧 将剩余代币转入 Uniswap 流动性池
- 🔥 销毁未售出的代币（防止砸盘）

---

#### 场景 B：仍在公平启动窗口内 (498-557行)

```solidity
// 1. 防止在公平启动期间卖出代币
if (nativeIsZero != _params.zeroForOne) {
    revert FairLaunch.CannotSellTokenDuringFairLaunch();
}

// 2. 从公平启动位置填充交换请求
BalanceDelta fairLaunchFillDelta;
(beforeSwapDelta_, fairLaunchFillDelta, fairLaunchInfo) = 
    fairLaunch.fillFromPosition(_key, _params.amountSpecified, nativeIsZero);

// 3. 结算代币给 Uniswap V4
_settleDelta(_key, fairLaunchFillDelta);

// 4. 捕获费用（不全部给用户）
uint swapFee = _captureAndDepositFees(_key, _params, _sender, beforeSwapDelta_.getUnspecifiedDelta(), _hookData);

// 5. 更新收入记录（扣除费用）
if (_params.amountSpecified >= 0 && swapFee != 0) {
    fairLaunch.modifyRevenue(poolId, -swapFee.toInt128());
}

// 6. 如果代币售罄，关闭池
if (fairLaunchInfo.supply == 0) {
    fairLaunch.closePosition({...});
}
```

**功能详解：**
- 🚫 **禁止卖出**：公平启动期间只能买入，不能卖出
- 💰 **填充交换**：从公平启动单边流动性位置填充买入订单
- 💸 **费用捕获**：捕获并分配费用（不全部给用户）
- 📊 **收入跟踪**：更新公平启动收入记录
- 🔚 **自动关闭**：代币售罄时自动关闭位置

---

### 阶段 3️⃣：清理临时存储 (560-571行)

```solidity
// 删除预挖的临时存储数据，防止在多个交换中重复触发
{
    PoolId poolId = _key.toId();
    assembly {
        tstore(poolId, 0)  // 清除 transient storage
    }
}
```

**功能：**
- 🧹 防止预挖在多个 swap 中重复触发
- 💾 使用 transient storage（仅在一个交易内有效）
- 🔒 确保预挖只能执行一次

---

### 阶段 4️⃣：内部交换池（Internal Swap Pool）处理 (573-611行)

**核心思想：** 在进入 Uniswap 池之前，用累积的费用代币填充部分 swap。

```solidity
// 检查是否有 token1 费用代币可以用来填充交换
(uint tokenIn, uint tokenOut) = _internalSwap(poolManager, _key, _params, nativeIsZero);

if (tokenIn + tokenOut != 0) {
    // 计算内部交换的 delta
    BeforeSwapDelta internalBeforeSwapDelta = _params.amountSpecified >= 0
        ? toBeforeSwapDelta(-tokenOut.toInt128(), tokenIn.toInt128())
        : toBeforeSwapDelta(tokenIn.toInt128(), -tokenOut.toInt128());
    
    // 捕获内部交换的费用
    uint swapFee = _captureAndDepositFees(_key, _params, _sender, internalBeforeSwapDelta.getUnspecifiedDelta(), _hookData);
    
    // 更新 beforeSwapDelta，减少后续 Uniswap 交换的金额
    beforeSwapDelta_ = toBeforeSwapDelta(
        beforeSwapDelta_.getSpecifiedDelta() + internalBeforeSwapDelta.getSpecifiedDelta(),
        beforeSwapDelta_.getUnspecifiedDelta() + internalBeforeSwapDelta.getUnspecifiedDelta() + swapFee.toInt128()
    );
}
```

**功能详解：**
- 🎯 **前置填充**：用累积的费用代币（token1）在进入主池前填充部分 swap
- 📉 **减少冲击**：降低对主池的价格影响和滑点
- ⛽ **Gas 优化**：内部处理比池内交换更省 gas
- 📚 **订单簿功能**：作为部分订单簿，平滑价格波动

**工作原理：**
```
用户想用 100 ETH 买 Token
    ↓
ISP 检查：有 20 Token 的费用余额
    ↓
ISP 内部交换：20 Token → 5 ETH
    ↓
剩余 95 ETH 进入 Uniswap 池
    ↓
结果：减少了对主池的冲击
```

---

### 阶段 5️⃣：BidWall 状态检查 (617-623行)

```solidity
// 捕获当前 tick 值
(, _beforeSwapTick,,) = poolManager.getSlot0(_key.toId());

// 检查 BidWall 是否变得陈旧，允许在构建阈值之前提取流动性
bidWall.checkStalePosition({
    _poolKey: _key,
    _currentTick: _beforeSwapTick,
    _nativeIsZero: nativeIsZero
});
```

**功能：**
- 🔍 检查 BidWall 流动性位置是否过时
- 💧 在价格偏离阈值时允许提取流动性
- 🛡️ 保护流动性提供者免受无常损失

---

## 📊 完整执行流程图

```
用户发起 Swap
    ↓
┌─────────────────────────────────────┐
│ [阶段1] 调度/预挖检查                │
│  ├─ 有调度？→ 检查时间/预挖          │
│  └─ 无调度 → 继续                    │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段2] 公平启动处理                 │
│  ├─ 窗口已结束？→ 关闭位置 + 销毁    │
│  └─ 窗口内？→ 填充交换 + 捕获费用   │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段3] 清理临时存储                 │
│  └─ 清除预挖标记                     │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段4] 内部交换池                   │
│  └─ 用费用代币填充部分交换           │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│ [阶段5] BidWall 检查                 │
│  └─ 检查流动性位置状态               │
└─────────────────────────────────────┘
    ↓
返回 beforeSwapDelta → Uniswap V4 执行实际交换
```

---

## 🎯 核心设计理念

### 1. **公平启动保护**
- 🚫 禁止在公平启动期间卖出
- 💰 确保价格稳定，防止早期砸盘
- ⏰ 时间窗口保护机制

### 2. **费用优化策略**
- 📊 内部交换池减少对主池的冲击
- 💸 智能费用捕获和分配
- 📈 提升整体协议收益

### 3. **自动化管理**
- 🤖 自动关闭公平启动位置
- 🔥 自动销毁未售出代币
- 🧹 自动清理临时状态

### 4. **安全性保障**
- 🔒 使用 transient storage 防止重入
- ✅ 多重验证机制
- 🛡️ 防止恶意操作

---

## 🔑 关键数据结构

### BeforeSwapDelta
```solidity
struct BeforeSwapDelta {
    int128 specifiedDelta;    // 指定货币的 delta
    int128 unspecifiedDelta;  // 未指定货币的 delta
}
```

**含义：**
- **Positive**: hook 欠用户/从池中取出
- **Negative**: hook 欠池/向池中存入

### 临时存储（Transient Storage）
- 使用 `tstore`/`tload` 存储预挖信息
- 仅在单个交易内有效
- 交易结束后自动清除

---

## 📝 相关事件

- `PoolPremine(PoolId indexed _poolId, int _premineAmount)` - 预挖成功
- `FairLaunchBurn(PoolId indexed _poolId, uint _unsoldSupply)` - 销毁未售出代币
- `PoolSwap(...)` - 池交换事件（包含各阶段数据）

---

## 🔗 相关模块

- **FairLaunch**: 公平启动逻辑
- **InternalSwapPool**: 内部交换池
- **FeeDistributor**: 费用分配
- **BidWall**: 流动性墙

---

## 💡 设计亮点

1. **多阶段处理**：将复杂逻辑拆分为清晰的阶段
2. **前置优化**：在进入主池前完成大部分处理
3. **自动化**：减少人工干预，提升用户体验
4. **安全性**：多重验证和防护机制

---

## ⚠️ 注意事项

1. **预挖限制**：必须在同一区块且金额完全匹配
2. **公平启动期间**：只能买入，不能卖出
3. **桥接窗口**：1小时内不能重复触发桥接
4. **临时存储**：每个交易后自动清除

