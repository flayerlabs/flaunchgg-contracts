# Manager Types Reference

## AddressFeeSplitManager

Split fees between fixed addresses with immutable percentages.

**Use case:** Team revenue sharing, DAO treasury allocation

### Initialize Parameters

```solidity
struct InitializeParams {
    uint creatorShare;              // Share to token depositor (5 decimals)
    uint ownerShare;                // Share to manager owner (5 decimals)
    RecipientShare[] recipientShares; // Remaining split recipients
}

struct RecipientShare {
    address recipient;
    uint share;                     // 5 decimals: 50_00000 = 50%
}
```

### Example

```solidity
// Build recipient shares array
AddressFeeSplitManager.RecipientShare[] memory recipientShares = 
    new AddressFeeSplitManager.RecipientShare[](2);
recipientShares[0] = AddressFeeSplitManager.RecipientShare({
    recipient: treasury,
    share: 50_00000     // 50% of split share
});
recipientShares[1] = AddressFeeSplitManager.RecipientShare({
    recipient: marketing,
    share: 50_00000     // 50% of split share
});

// Create init params
AddressFeeSplitManager.InitializeParams memory params = 
    AddressFeeSplitManager.InitializeParams({
        creatorShare: 10_00000,      // 10% to creator
        ownerShare: 5_00000,         // 5% to manager owner
        recipientShares: recipientShares  // 85% split among recipients
    });
```

### Contract Addresses

| Network | Address |
|---------|---------|
| Base Mainnet | `0xf6d8018450109A68acfBCD2523dc43fB31920a7D` |
| Base Sepolia | `0xf72dcdee692c188de6b14c6213e849982e04069b` |

---

## StakingManager

Distribute fees to users who stake an ERC20 token.

**Use case:** Holder incentives, liquidity mining

### Initialize Parameters

```solidity
struct InitializeParams {
    address stakingToken;           // Token users stake
    uint minEscrowDuration;         // Lock period for NFT
    uint minStakeDuration;          // Lock period for stakes
    uint creatorShare;              // Share to creator (5 decimals)
    uint ownerShare;                // Share to owner (5 decimals)
}
```

### Example

```solidity
StakingManager.InitializeParams({
    stakingToken: tokenAddress,
    minEscrowDuration: 30 days,
    minStakeDuration: 7 days,
    creatorShare: 10_00000,         // 10%
    ownerShare: 5_00000             // 5%
})
// Remaining 85% distributed to stakers proportionally
```

### How Staking Works

1. Users call `stake(amount)` to deposit tokens
2. Stakes are locked for `minStakeDuration`
3. Fees accumulate proportional to stake size
4. Users call `claim()` to withdraw earned fees
5. Users call `unstake(amount)` after lock period

### Contract Addresses

| Network | Address |
|---------|---------|
| Base Mainnet | `0xa15F92a7C09a7D6ADbc00FF2DB63e414fBFEA193` |
| Base Sepolia | `0x8Ea4074c38cA7a596C740DD9E9D7122ea8E78c3c` |

---

## BuyBackManager

Route fees to the BidWall for automatic token buybacks.

**Use case:** Deflationary tokenomics, price support

### Initialize Parameters

```solidity
struct InitializeParams {
    uint creatorShare;              // Share to creator (5 decimals)
    uint ownerShare;                // Share to owner (5 decimals)
    PoolKey buyBackPoolKey;         // Target pool for buybacks
}
```

### Example

```solidity
BuyBackManager.InitializeParams({
    creatorShare: 10_00000,         // 10% to creator
    ownerShare: 0,                  // 0% to owner
    buyBackPoolKey: poolKey         // Remaining 90% to buybacks
})
```

### How Buybacks Work

1. Trading fees accumulate in the manager
2. Fees are routed to the BidWall
3. BidWall places buy orders on Uniswap V4
4. Bought tokens are burned or held

---

## RevenueManager

Simple creator revenue collection with optional protocol fee.

**Use case:** Basic fee collection for external protocols building on Flaunch

**Note:** This manager extends `TreasuryManager` directly (not `FeeSplitManager`) and uses a different parameter model.

### Initialize Parameters

```solidity
struct InitializeParams {
    address payable protocolRecipient;  // Address to receive protocol fees
    uint protocolFee;                   // Protocol fee (2 decimals: 1000 = 10%)
}
```

### Example

```solidity
RevenueManager.InitializeParams({
    protocolRecipient: payable(0xProtocolWallet),
    protocolFee: 10_00    // 10% protocol fee (2 decimals)
})
```

### Contract Addresses

| Network | Address |
|---------|---------|
| Base Mainnet | `0x1af9B9f168bFd2046f45E0Ce03972864BcE7eE36` |
| Base Sepolia | `0x17E02501dE3e420347e7C5fCAe3AD787C5aea690` |

---

## ERC721OwnerFeeSplitManager

Split fees based on NFT ownership across multiple collections.

**Use case:** NFT holder rewards, cross-collection fee sharing

### Initialize Parameters

```solidity
struct InitializeParams {
    uint creatorShare;              // Share to creator (5 decimals)
    uint ownerShare;                // Share to owner (5 decimals)
    ERC721Share[] shares;           // NFT collections and their shares
}

struct ERC721Share {
    address erc721;                 // NFT collection address
    uint share;                     // Share percentage (5 decimals)
    uint totalSupply;               // Total NFTs in collection
}
```

### Example

```solidity
ERC721OwnerFeeSplitManager.ERC721Share[] memory shares = 
    new ERC721OwnerFeeSplitManager.ERC721Share[](2);
shares[0] = ERC721OwnerFeeSplitManager.ERC721Share({
    erc721: nftCollectionA,
    share: 60_00000,      // 60% to collection A holders
    totalSupply: 10000
});
shares[1] = ERC721OwnerFeeSplitManager.ERC721Share({
    erc721: nftCollectionB,
    share: 40_00000,      // 40% to collection B holders
    totalSupply: 5000
});

ERC721OwnerFeeSplitManager.InitializeParams({
    creatorShare: 10_00000,   // 10% to creator
    ownerShare: 5_00000,      // 5% to owner
    shares: shares            // 85% split among NFT holders
})
```

### How It Works

1. Fees accumulate in the manager
2. NFT holders claim by providing their token IDs
3. Each NFT receives an equal share within its collection
4. Claims require proving ownership at claim time

### Contract Addresses

| Network | Address |
|---------|---------|
| Base Sepolia | `0xc98a11e6292bbafb8f55e09a3eef44ba1410a142` |

---

## Share Calculation

All shares use 5 decimal places:

| Value | Percentage |
|-------|------------|
| `100_00000` | 100% |
| `50_00000` | 50% |
| `10_00000` | 10% |
| `1_00000` | 1% |
| `50000` | 0.5% |

**Rules for `FeeSplitManager`-based managers:**
- `creatorShare + ownerShare <= 100_00000`
- `sum(recipientShares) = 100_00000` (recipients split the remaining portion)

The split share = `100_00000 - creatorShare - ownerShare`. Recipients divide this among themselves according to their shares (which must sum to 100_00000).
