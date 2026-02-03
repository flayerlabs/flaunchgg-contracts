# SDK Usage Reference

The Flaunch SDK provides programmatic access to launch tokens and interact with the protocol.

## Installation

```bash
npm install @flaunch/sdk viem
```

## Initialization

### Read-Only Client

For querying token data without a wallet:

```typescript
import { createFlaunch } from "@flaunch/sdk";
import { createPublicClient, http } from "viem";
import { base, baseSepolia } from "viem/chains";

const publicClient = createPublicClient({
  chain: base, // or baseSepolia for testnet
  transport: http(),
});

const sdk = createFlaunch({ publicClient });
```

### Read-Write Client

For launching tokens and executing transactions:

```typescript
import { createFlaunch } from "@flaunch/sdk";
import { createPublicClient, createWalletClient, http } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const publicClient = createPublicClient({
  chain: base,
  transport: http(),
});

const walletClient = createWalletClient({
  account: privateKeyToAccount("0xYourPrivateKey"),
  chain: base,
  transport: http(),
});

const sdk = createFlaunch({ publicClient, walletClient });
```

---

## Token Validation

### Check if Address is Valid Flaunch Token

```typescript
const isValid = await sdk.isValidCoin("0xTokenAddress");
console.log(isValid); // true or false
```

### Get Token Version

```typescript
const version = await sdk.getCoinVersion("0xTokenAddress");
console.log(version); // "V1_2"
```

---

## Launching Tokens

### Basic Launch

```typescript
const txHash = await sdk.readWriteFlaunchZap.flaunch({
  name: "My Token",
  symbol: "TOKEN",
  tokenUri: "ipfs://QmYourImageHash",
  fairLaunchPercent: 0,           // SDK requires 0 (fair launch via direct contract)
  fairLaunchDuration: 0,          // SDK requires 0 (fair launch via direct contract)
  initialMarketCapUSD: 10000,     // $10k starting mcap
  creator: "0xYourAddress",
  creatorFeeAllocationPercent: 20,
});
```

**Note:** The SDK currently requires fair launch parameters to be 0. For tokens with fair launch, use the protocol contracts directly.

### Launch with Split Manager

Launch with automatic fee splitting to multiple addresses:

```typescript
const txHash = await sdk.readWriteFlaunchZap.flaunchWithSplitManager({
  name: "Split Token",
  symbol: "SPLIT",
  tokenUri: "ipfs://QmYourImageHash",
  fairLaunchPercent: 0,
  fairLaunchDuration: 0,
  initialMarketCapUSD: 10000,
  creator: "0xYourAddress",
  creatorFeeAllocationPercent: 20,
  creatorSplitPercent: 10,        // 10% to creator
  managerOwnerSplitPercent: 5,    // 5% to manager owner
  splitReceivers: [
    { address: "0xRecipient1", percent: 50 },
    { address: "0xRecipient2", percent: 50 },
  ],
});
```

---

## Waiting for Confirmation

```typescript
const txHash = await sdk.readWriteFlaunchZap.flaunch({...});

// Wait for transaction to be mined
const receipt = await publicClient.waitForTransactionReceipt({ 
  hash: txHash 
});

console.log("Status:", receipt.status); // "success"
console.log("Block:", receipt.blockNumber);

// Find the new token address in logs
for (const log of receipt.logs) {
  const isValid = await sdk.isValidCoin(log.address);
  if (isValid) {
    console.log("New token:", log.address);
    break;
  }
}
```

---

## SDK Properties

| Property | Description |
|----------|-------------|
| `sdk.chainId` | Current chain ID |
| `sdk.readFlaunchZap` | Read-only FlaunchZap methods |
| `sdk.readWriteFlaunchZap` | Read-write FlaunchZap methods |
| `sdk.readPositionManagerV1_2` | Position manager queries |

---

## Networks

| Network | Chain | Chain ID |
|---------|-------|----------|
| Base Mainnet | `base` | 8453 |
| Base Sepolia | `baseSepolia` | 84532 |

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `FairLaunch has been deprecated` | `fairLaunchPercent > 0` | Set to 0 |
| `CreatorCannotBeZero` | `creator` is zero address | Provide valid address |
| `InsufficientMemecoinsForAirdrop` | Airdrop amount too high | Reduce airdrop |
