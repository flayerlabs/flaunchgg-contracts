# Token Launching

Launch memecoins on Base via Flaunch. Choose between the gasless API for simplicity or the SDK for programmatic control.

## Why Flaunch?

- **No upfront cost**: Gasless API requires no wallet or ETH
- **100% fee control**: You own all trading fee revenue
- **Instant liquidity**: Tokens are immediately tradeable on Uniswap V4
- **Built-in protection**: BidWall prevents rug pulls

## Two Paths to Launch

| Method | Wallet Needed | Best For |
|--------|---------------|----------|
| **Gasless API** | No | Quick launches, experiments |
| **SDK** | Yes | Programmatic control, premine |

---

## Path 1: Gasless API

The gasless API handles everything server-side. No wallet, no ETH, no gas.

### Step 1: Upload Token Image

```bash
curl -X POST https://web2-api.flaunch.gg/api/v1/upload-image \
  -H "Content-Type: application/json" \
  -d '{
    "base64Image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB..."
  }'
```

Response:

```json
{
  "success": true,
  "ipfsHash": "QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo",
  "tokenURI": "ipfs://QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo"
}
```

### Step 2: Launch Token

```bash
# Base Mainnet
curl -X POST https://web2-api.flaunch.gg/api/v1/base/launch-memecoin \
  -H "Content-Type: application/json" \
  -d '{
    "name": "My Token",
    "symbol": "TOKEN",
    "description": "A token launched by an AI agent",
    "imageIpfs": "QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo",
    "creatorAddress": "0xYourAddress..."
  }'
```

Response:

```json
{
  "success": true,
  "message": "Memecoin launch request queued",
  "jobId": "12345"
}
```

### Step 3: Check Status

```bash
curl https://web2-api.flaunch.gg/api/v1/launch-status/12345
```

Response when complete:

```json
{
  "success": true,
  "state": "completed",
  "transactionHash": "0x...",
  "collectionToken": {
    "address": "0xNewTokenAddress...",
    "name": "My Token",
    "symbol": "TOKEN"
  }
}
```

Your token is now live at `https://flaunch.gg/base/coin/0xNewTokenAddress`

See [references/gasless-api.md](./references/gasless-api.md) for full API documentation.

---

## Path 2: SDK

For programmatic control with a wallet.

### Installation

```bash
npm install @flaunch/sdk viem
```

### Basic Launch

```typescript
import { createFlaunch } from "@flaunch/sdk";
import { createPublicClient, createWalletClient, http } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

// Initialize clients
const publicClient = createPublicClient({
  chain: base,
  transport: http(),
});

const walletClient = createWalletClient({
  account: privateKeyToAccount("0xYourPrivateKey"),
  chain: base,
  transport: http(),
});

// Create SDK instance
const sdk = createFlaunch({ publicClient, walletClient });

// Launch token
const txHash = await sdk.readWriteFlaunchZap.flaunch({
  name: "SDK Token",
  symbol: "SDKTKN",
  tokenUri: "ipfs://QmYourImageHash...",
  fairLaunchPercent: 0,           // SDK requires 0
  fairLaunchDuration: 0,          // SDK requires 0
  initialMarketCapUSD: 10000,     // $10k starting mcap
  creator: "0xYourAddress",
  creatorFeeAllocationPercent: 20, // 20% of trading fees
});

// Wait for confirmation
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log("Token launched:", receipt.status);
```

See [references/sdk-usage.md](./references/sdk-usage.md) for advanced SDK features.

---

## Launch Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `initialMarketCapUSD` | 10000 | Starting market cap in USD |
| `creatorFeeAllocationPercent` | 20 | % of BidWall fees you receive |
| `fairLaunchPercent` | 0 | SDK requires 0 (protocol supports fair launch) |
| `fairLaunchDuration` | 0 | SDK requires 0 (protocol supports fair launch) |

---

## After Launch

Once launched, you receive:

1. **Token address** - The ERC20 memecoin contract
2. **ERC721 NFT** - Represents ownership of the fee stream
3. **Trading fees** - Accumulate as the token is traded

### Verify Your Token

```typescript
const isValid = await sdk.isValidCoin("0xTokenAddress");
const version = await sdk.getCoinVersion("0xTokenAddress");
```

---

## Tips

1. **Test on Sepolia first** - Use `base-sepolia` endpoint and `baseSepolia` chain
2. **Use descriptive metadata** - Good name, symbol, description help discovery
3. **Set `fairLaunchPercent: 0`** - Fair launch is deprecated
4. **Monitor your job** - Poll `/launch-status/{jobId}` until `state: "completed"`

---

## References

- [Gasless API](./references/gasless-api.md) - Full API endpoint documentation
- [SDK Usage](./references/sdk-usage.md) - SDK methods and examples
- [Contract Addresses](./references/contract-addresses.md) - Deployed contract addresses
- [FlaunchParams](./references/flaunch-params.md) - Parameter encoding details
