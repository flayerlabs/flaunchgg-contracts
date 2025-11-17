# Flaunch.sol 合约功能梳理

## 📋 合约整体架构

**Flaunch** 是一个 ERC721 NFT 合约，每个 NFT 代表一个 Meme 币项目的所有权凭证。它整合了：
- **ERC721**：持有者拥有该 Meme 币项目的管理权
- **跨链桥接**：支持 Superchain L2 之间的代币跨链
- **工厂模式**：使用 Clone 模式部署 Memecoin 和 Treasury

---

## 🎯 核心功能模块

### 1️⃣ **代币发行系统 (Flaunch)**

**函数：** `flaunch(PositionManager.FlaunchParams calldata _params)`

**流程：**
1. ✅ **参数验证**
   - 检查发行时间是否超过最大调度时长（30天）
   - 验证初始供应量是否在允许范围内
   - 检查预挖数量是否超过初始供应量
   - 验证创建者费用分配是否超过最大值（100%）

2. 🎫 **铸造所有权 NFT**
   - 将 ERC721 NFT 铸造给创建者（`_params.creator`）
   - 每个 NFT 代表一个 Memecoin 项目的所有权

3. 💰 **部署 Memecoin 合约**
   - 使用 `LibClone.cloneDeterministic` 部署 ERC20 Memecoin
   - 使用 `tokenId` 作为 salt，确保地址确定性
   - 初始化代币元数据（name, symbol, tokenUri）

4. 🏦 **部署 MemecoinTreasury 合约**
   - 使用相同的 salt 部署金库合约
   - 用于管理项目的资金

5. 📦 **铸造初始供应量**
   - 将 `TokenSupply.INITIAL_SUPPLY` 铸造到 `PositionManager`
   - 用于后续的公平启动和流动性提供

**关键代码位置：** `src/contracts/Flaunch.sol:146-192`

---

### 2️⃣ **跨链桥接系统**

#### 初始化桥接：`initializeBridge(uint _tokenId, uint _chainId)`

**功能：**
- 验证目标链不是当前链
- 检查桥接是否已完成
- 防止在桥接窗口期内重复触发（1小时窗口）
- 获取 Memecoin 元数据
- 通过 `L2ToL2CrossDomainMessenger` 发送跨链消息

**关键代码位置：** `src/contracts/Flaunch.sol:334-387`

#### 完成桥接：`finalizeBridge(uint _tokenId, MemecoinMetadata memory _metadata)`

**功能：**
- 验证跨域消息来源（只能由自己发送的消息触发）
- 使用相同的 salt（tokenId）在目标链部署 Memecoin
- 初始化元数据，保持跨链地址一致性
- 标记桥接为已完成

**关键代码位置：** `src/contracts/Flaunch.sol:396-408`

**跨链流程：**
```
L2-A 链：initializeBridge()
    ↓
L2ToL2CrossDomainMessenger.sendMessage()
    ↓
L2-B 链：finalizeBridge() (自动触发)
    ↓
部署相同地址的 Memecoin
```

---

### 3️⃣ **权限管理与元数据**

#### `setMemecoinMetadata(address _memecoin, string calldata name_, string calldata symbol_)`
- 允许合约所有者修复不当的元数据（恶意内容、格式错误等）

#### `setBaseURI(string memory _baseURI)`
- 更新 ERC721 NFT 的基础 URI

#### `setMemecoinImplementation(address _memecoinImplementation)`
- 升级 Memecoin 实现合约地址

#### `setMemecoinTreasuryImplementation(address _memecoinTreasuryImplementation)`
- 升级 MemecoinTreasury 实现合约地址

**关键代码位置：** `src/contracts/Flaunch.sol:203-239`

---

### 4️⃣ **查询接口**

#### `memecoin(uint _tokenId) → address`
- 根据 NFT tokenId 返回对应的 Memecoin 地址

#### `memecoinTreasury(uint _tokenId) → address payable`
- 根据 NFT tokenId 返回对应的 MemecoinTreasury 地址

#### `poolId(uint _tokenId) → PoolId`
- 根据 NFT tokenId 返回对应的 Uniswap V4 PoolId

#### `tokenURI(uint _tokenId) → string`
- 返回 NFT 的元数据 URI
- 如果 baseURI 为空，返回 Memecoin 的 tokenURI
- 否则返回 `baseURI + tokenId`

**关键代码位置：** `src/contracts/Flaunch.sol:283-307`

---

## 🔐 安全机制

### 访问控制

#### `onlyPositionManager` 修饰符
- 只有 `PositionManager` 合约可以调用 `flaunch()` 函数
- 防止未授权的代币发行

#### `onlyCrossDomainCallback` 修饰符
- 验证消息发送者必须是 `L2ToL2CrossDomainMessenger`
- 验证跨域消息来源必须是合约自身
- 防止恶意跨链调用

**关键代码位置：** `src/contracts/Flaunch.sol:413-428`

### 参数限制

```solidity
uint public constant MAX_FAIR_LAUNCH_TOKENS = TokenSupply.INITIAL_SUPPLY;
uint public constant MAX_CREATOR_ALLOCATION = 100_00;  // 100%
uint public constant MAX_SCHEDULE_DURATION = 30 days;
uint public constant MAX_BRIDGING_WINDOW = 1 hours;
```

---

## 🔄 关键设计模式

### 1. **确定性部署（Deterministic Deployment）**
- 使用 `LibClone.cloneDeterministic` + `tokenId` 作为 salt
- 保证跨链部署时地址一致
- 便于跨链状态同步

### 2. **代理模式（Clone Pattern）**
- 所有 Memecoin 和 Treasury 都是最小代理（minimal proxy）
- 大幅降低部署成本
- 便于统一升级

### 3. **所有权 NFT 模式**
- 持有 ERC721 NFT = 拥有 Memecoin 项目的控制权
- 可以转移所有权
- 便于治理和收益分配

### 4. **重试机制**
- 桥接失败后，1小时窗口期后可重试
- 防止永久锁定状态

---

## 📊 数据流总结

```
用户 → PositionManager.flaunch()
    ↓
Flaunch.flaunch()
    ├─ 铸造 ERC721 NFT
    ├─ 部署 Memecoin (ERC20)
    ├─ 部署 MemecoinTreasury
    └─ 铸造初始供应到 PositionManager
    
ERC721 持有者 → initializeBridge()
    ↓
L2ToL2Messenger
    ↓
目标链 finalizeBridge()
    └─ 部署相同地址的 Memecoin
```

---

## 📝 重要事件

- `TokenBridging(uint _tokenId, uint _chainId, address _memecoin)` - 开始桥接
- `TokenBridged(uint _tokenId, uint _chainId, address _memecoin, uint _messageSource)` - 完成桥接
- `BaseURIUpdated(string _newBaseURI)` - 更新基础 URI
- `MemecoinImplementationUpdated(address _newImplementation)` - 更新实现地址
- `MemecoinTreasuryImplementationUpdated(address _newImplementation)` - 更新金库实现地址

---

## 🔗 相关合约

- **PositionManager**: 调用 `flaunch()` 创建新代币
- **Memecoin**: ERC20 代币实现
- **MemecoinTreasury**: 金库合约实现
- **L2ToL2CrossDomainMessenger**: Optimism 跨链消息传递

---

## 💡 设计亮点

1. **跨链一致性**：通过确定性部署保证跨链地址相同
2. **成本优化**：使用 Clone 模式大幅降低部署成本
3. **灵活治理**：通过 NFT 所有权实现项目控制权转移
4. **安全可靠**：多重验证机制防止恶意操作

