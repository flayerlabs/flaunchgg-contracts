# Treasury Managers

Control how trading fees are distributed with treasury managers. This is the power feature that sets Flaunch apart from other launchpads.

## Why Treasury Managers?

When you launch a token on Flaunch, you receive an ERC721 NFT that represents ownership of the token's fee stream. By default, fees go to the NFT holder. But with treasury managers, you can program sophisticated fee distribution logic.

**What you can do:**
- Split fees between multiple addresses
- Create staking pools where holders earn from trading fees
- Route fees to automatic token buybacks
- Build gamified incentives and competitions
- Any custom logic you can imagine

---

## How Fees Work

Every trade on a Flaunch token generates fees that flow to the BidWall. The `creatorFeeAllocation` you set at launch determines your share.

```
Trading Fees → BidWall → Creator Fee Allocation → Treasury Manager → Distribution
```

### Fee Tiers (FeeSplitManager-based)

Managers that extend `FeeSplitManager` (AddressFeeSplit, Staking, BuyBack, ERC721Owner) support three tiers:

| Tier | Description |
|------|-------------|
| **Creator Share** | Goes to the address that deposited the token |
| **Owner Share** | Goes to the manager owner (you) |
| **Split Share** | Distributed per manager logic |

Shares use 5 decimal places: `100_00000` = 100%

**Note:** `RevenueManager` uses a different model with `protocolRecipient` and `protocolFee` instead.

---

## Available Managers

| Manager | Use Case |
|---------|----------|
| `AddressFeeSplitManager` | Split fees between fixed addresses |
| `StakingManager` | Distribute fees to token stakers |
| `BuyBackManager` | Route fees to token buybacks |
| `RevenueManager` | Simple creator + protocol split |
| `ERC721OwnerFeeSplitManager` | Split based on NFT ownership |

See [references/manager-types.md](./references/manager-types.md) for detailed parameters.

---

## Using Managers

### Option 1: Launch with Manager (SDK)

```typescript
import { createFlaunch } from "@flaunch/sdk";

const sdk = createFlaunch({ publicClient, walletClient });

// Launch with AddressFeeSplitManager
const txHash = await sdk.readWriteFlaunchZap.flaunchWithSplitManager({
  name: "Split Token",
  symbol: "SPLIT",
  tokenUri: "ipfs://Qm...",
  fairLaunchPercent: 0,
  fairLaunchDuration: 0,
  initialMarketCapUSD: 10000,
  creator: "0xYourAddress",
  creatorFeeAllocationPercent: 20,
  creatorSplitPercent: 10,        // 10% to creator
  managerOwnerSplitPercent: 5,    // 5% to manager owner
  splitReceivers: [
    { address: "0xTreasury", percent: 50 },
    { address: "0xMarketing", percent: 35 },
  ],
});
```

### Option 2: Deploy Manager Separately

```solidity
address manager = treasuryManagerFactory.deployAndInitializeManager(
    addressFeeSplitManagerImpl,
    owner,
    initializeData
);
```

See [references/factory-usage.md](./references/factory-usage.md) for factory details.

---

## Manager Examples

### Revenue Split

Split trading fees between team, treasury, and marketing:

```typescript
const splitReceivers = [
  { address: "0xTeamWallet", percent: 40 },
  { address: "0xTreasury", percent: 35 },
  { address: "0xMarketing", percent: 25 },
];
```

### Staking Rewards

Let holders stake tokens to earn from trading fees:

```solidity
StakingManager.InitializeParams({
    stakingToken: tokenAddress,
    minEscrowDuration: 30 days,
    minStakeDuration: 7 days,
    creatorShare: 10_00000,   // 10%
    ownerShare: 5_00000       // 5%
})
// Remaining 85% split among stakers proportionally
```

### Deflationary Buyback

Route all fees to buy and burn tokens:

```solidity
BuyBackManager.InitializeParams({
    creatorShare: 10_00000,
    ownerShare: 0,
    buyBackPoolKey: poolKey
})
```

---

## Transferring Fee Ownership

The ERC721 NFT represents fee stream ownership. You can move this ownership to:

1. **A manager contract** - Enable programmatic distribution (via `deposit`)
2. **A multisig** - Shared control over fees
3. **Another wallet** - Sell or delegate fee rights

```typescript
// Direct transfer to another wallet
await nftContract.transferFrom(owner, newOwner, tokenId);

// Deposit into a treasury manager (proper method)
await nftContract.approve(managerAddress, tokenId);
await treasuryManager.deposit(flaunchToken, creatorAddress, depositData);
```

**Important:** Don't use `safeTransferFrom` directly to a manager. Managers track deposits via their `deposit()` function which handles internal accounting.

---

## Building Custom Managers

Extend `TreasuryManager` or `FeeSplitManager` for custom logic:

```solidity
contract MyCustomManager is FeeSplitManager {
    function _initialize(address _owner, bytes calldata _data) internal override {
        // Your initialization logic
    }
    
    function balances(address recipient) public view override returns (uint) {
        // Your balance calculation
    }
}
```

See [references/custom-managers.md](./references/custom-managers.md) for the full interface.

---

## Tips

1. **Plan your tokenomics** before launch - manager params are often immutable
2. **Use testnet first** - Deploy on Base Sepolia before mainnet
3. **Consider gas costs** - Complex distribution logic costs more gas
4. **Audit custom managers** - Bugs in fee distribution can lock funds
5. **Document for holders** - Be transparent about how fees are distributed

---

## References

- [Manager Types](./references/manager-types.md) - All managers with init params
- [Fee Distribution](./references/fee-distribution.md) - How fees flow
- [Factory Usage](./references/factory-usage.md) - Deploying managers
- [Custom Managers](./references/custom-managers.md) - Building your own
