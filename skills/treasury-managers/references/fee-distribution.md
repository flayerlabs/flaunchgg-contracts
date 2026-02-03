# Fee Distribution Reference

## Fee Flow Overview

```
┌─────────────┐     ┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│   Trading   │────▶│   BidWall   │────▶│ Creator Fee      │────▶│  Treasury   │
│   Activity  │     │             │     │ Allocation       │     │  Manager    │
└─────────────┘     └─────────────┘     └──────────────────┘     └─────────────┘
                                                                        │
                    ┌───────────────────────────────────────────────────┤
                    │                                                   │
                    ▼                                                   ▼
            ┌───────────────┐                                  ┌───────────────┐
            │ Creator Share │                                  │  Split Share  │
            └───────────────┘                                  └───────────────┘
                    │                                                   │
                    ▼                                                   ▼
            ┌───────────────┐                                  ┌───────────────┐
            │    Creator    │                                  │  Recipients/  │
            │    Wallet     │                                  │  Stakers/etc  │
            └───────────────┘                                  └───────────────┘
```

---

## Step-by-Step

### 1. Trade Occurs

User buys or sells the memecoin on Uniswap V4.

### 2. Fees Collected

Trading fees are collected by the Flaunch hooks and sent to the BidWall.

### 3. Creator Fee Allocation

The `creatorFeeAllocation` set at launch determines what percentage goes to the creator vs protocol.

```
creatorFeeAllocation = 2000  // 20%

Creator receives: 20% of trading fees
Protocol receives: 80% of trading fees
```

### 4. Treasury Manager Distribution

If a treasury manager is attached, fees are distributed according to manager logic:

```
Creator Share (10%) → Token depositor address
Owner Share (5%)    → Manager owner address  
Split Share (85%)   → Manager-specific logic
```

---

## Fee Calculation Example

**Scenario:**
- Trade volume: 1 ETH
- Trading fee: 1% (0.01 ETH)
- Creator fee allocation: 20%

**Calculation:**

```
Total trading fee:        0.01 ETH
Creator allocation (20%): 0.002 ETH  → Goes to Treasury Manager
BidWall allocation (80%): 0.008 ETH  → Provides liquidity support

If using AddressFeeSplitManager with:
- creatorShare: 10%
- ownerShare: 5%
- recipientShares: 100% (splitting the remaining 85%)

From the 0.002 ETH creator allocation:
Creator receives:  0.002 ETH × 10% = 0.0002 ETH
Owner receives:    0.002 ETH × 5%  = 0.0001 ETH
Recipients split:  0.002 ETH × 85% = 0.0017 ETH (divided per their shares)
```

**Note:** `recipientShares` must sum to 100_00000 (100%). They divide whatever remains after creator and owner shares.

---

## Fee Escrow

Fees don't go directly to managers. They accumulate in FeeEscrow contracts and are claimed periodically.

### Claiming Fees

```solidity
// ITreasuryManager interface
function claim() external;           // Claims for msg.sender
function balances(address) view;     // Check claimable balance

// Example usage
uint claimable = manager.balances(msg.sender);
if (claimable > 0) {
    manager.claim();  // Claims to msg.sender
}
```

### Escrow Addresses

| Network | FeeEscrow Address |
|---------|-------------------|
| Base Mainnet | `0x72e6f7948b1B1A343B477F39aAbd2E35E6D27dde` |
| Base Sepolia | `0x73e27908b7d35a9251a54799a8ef4c17e4ed9ff9` |

---

## ERC721 Ownership

The ERC721 NFT minted at launch represents ownership of the fee stream.

### Default Behavior

- NFT holder receives all creator fees
- Transfer NFT = transfer fee rights

### With Manager

- NFT is deposited into manager contract
- Manager distributes fees per its logic
- Original depositor tracked as "creator"

### Transferring Ownership

```typescript
// Transfer NFT to new owner (direct ownership)
await flaunchNFT.transferFrom(currentOwner, newOwner, tokenId);

// Or deposit into a treasury manager:
// 1) Approve the manager to move the NFT
await flaunchNFT.approve(managerAddress, tokenId);

// 2) Call the manager's deposit function
await treasuryManager.deposit(flaunchToken, creatorAddress, depositData);

// Note: FlaunchZap can perform the deposit during launch automatically
```

---

## Gas Considerations

| Action | Approximate Gas |
|--------|-----------------|
| Claim from RevenueManager | ~50,000 |
| Claim from AddressFeeSplitManager | ~80,000 |
| Claim from StakingManager | ~120,000 |
| Stake tokens | ~100,000 |
| Unstake tokens | ~80,000 |

---

## Accumulation Period

Fees accumulate continuously but are only claimable after sufficient amounts build up. Most managers have minimum thresholds to prevent dust claims that waste gas.
