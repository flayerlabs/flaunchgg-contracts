# FlaunchParams Reference

The `FlaunchParams` struct defines all parameters for launching a token via the FlaunchZap contract.

## Struct Definition

```solidity
struct FlaunchParams {
    string name;                    // Token name
    string symbol;                  // Token symbol
    string tokenUri;                // IPFS metadata URI
    uint initialTokenFairLaunch;    // DEPRECATED - set to 0
    uint fairLaunchDuration;        // DEPRECATED - set to 0
    uint premineAmount;             // Tokens creator buys at launch
    address creator;                // Receives ERC721 + premined tokens
    uint24 creatorFeeAllocation;    // Fee share (2 decimals: 2000 = 20%)
    uint flaunchAt;                 // Launch timestamp (0 = immediate)
    bytes initialPriceParams;       // Encoded initial market cap
    bytes feeCalculatorParams;      // Fee calculator params
}
```

---

## Parameter Details

### name
Token name displayed in wallets and explorers.
- **Type:** `string`
- **Max length:** 32 characters
- **Example:** `"My Awesome Token"`

### symbol
Token ticker symbol.
- **Type:** `string`
- **Max length:** 10 characters
- **Example:** `"MAT"`

### tokenUri
IPFS URI containing token metadata (image, description).
- **Type:** `string`
- **Format:** `ipfs://Qm...`
- **Example:** `"ipfs://QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo"`

### initialTokenFairLaunch
Tokens allocated for fair launch phase (optional).
- **Type:** `uint256`
- **Example:** `10e27` = 10% of total supply
- **Default:** `0` (no fair launch)

**Note:** The SDK currently requires this to be 0. For fair launch functionality, use the protocol contracts directly.

### fairLaunchDuration
Duration of fair launch in seconds (optional).
- **Type:** `uint256`
- **Example:** `86400` = 24 hours
- **Default:** `0` (no fair launch)

**Note:** The SDK currently requires this to be 0. For fair launch functionality, use the protocol contracts directly.

### premineAmount
Number of tokens the creator buys at launch (in wei).
- **Type:** `uint256`
- **Example:** `5e27` = 5% of total supply (100e27)
- **Default:** `0` (no premine)

### creator
Address that receives the ERC721 ownership NFT and any premined tokens.
- **Type:** `address`
- **Cannot be:** Zero address

### creatorFeeAllocation
Percentage of BidWall fees the creator receives.
- **Type:** `uint24`
- **Decimals:** 2 (2000 = 20%)
- **Range:** 0 - 10000 (0% - 100%)
- **Example:** `2000` = 20%

### flaunchAt
Unix timestamp when the token becomes tradeable.
- **Type:** `uint256`
- **Value:** `0` = launch immediately
- **Example:** `block.timestamp + 24 hours`

### initialPriceParams
ABI-encoded initial market cap in USD (6 decimals).
- **Type:** `bytes`
- **Encoding:** `abi.encode(uint256)`
- **Example:** `abi.encode(10_000e6)` = $10,000 market cap

### feeCalculatorParams
Parameters for the fee calculator.
- **Type:** `bytes`
- **Default:** `abi.encode(0)`

---

## Encoding Examples

### TypeScript (viem)

```typescript
import { encodeAbiParameters } from "viem";

// Encode $10k market cap
const initialPriceParams = encodeAbiParameters(
  [{ type: "uint256" }],
  [BigInt(10000 * 1e6)]
);

// Encode fee calculator params
const feeCalculatorParams = encodeAbiParameters(
  [{ type: "uint256" }],
  [0n]
);
```

### Solidity

```solidity
bytes memory initialPriceParams = abi.encode(10_000e6); // $10k
bytes memory feeCalculatorParams = abi.encode(0);
```

---

## Common Configurations

### Minimal Launch

```typescript
{
  name: "Token",
  symbol: "TKN",
  tokenUri: "ipfs://Qm...",
  initialTokenFairLaunch: 0n,
  fairLaunchDuration: 0n,
  premineAmount: 0n,
  creator: "0xYourAddress",
  creatorFeeAllocation: 2000,     // 20%
  flaunchAt: 0n,                  // Immediate
  initialPriceParams: "0x...",    // $10k
  feeCalculatorParams: "0x...",
}
```

### With Premine

```typescript
{
  // ... same as above
  premineAmount: 5000000000000000000000000000n, // 5% of supply
}
```

### Delayed Launch

```typescript
{
  // ... same as above
  flaunchAt: BigInt(Math.floor(Date.now() / 1000) + 86400), // 24h from now
}
```
