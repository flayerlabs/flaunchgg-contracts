# Gasless API Reference

Base URL: `https://web2-api.flaunch.gg`

## Endpoints

### Upload Image

Upload a token image to IPFS.

```
POST /api/v1/upload-image
```

**Request:**

```json
{
  "base64Image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGQAAABk..."
}
```

**Response:**

```json
{
  "success": true,
  "ipfsHash": "QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo",
  "tokenURI": "ipfs://QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo",
  "nsfwDetection": {
    "isNSFW": false,
    "score": 0
  }
}
```

**Rate Limit:** 4 uploads per minute per IP

**Image Requirements:**
- Supported formats: PNG, JPEG, GIF, WebP
- Minimum size: 100x100 pixels
- Maximum size: 10MB
- NSFW content is rejected

---

### Launch Memecoin

Launch a new memecoin on the specified network.

```
POST /api/v1/{network}/launch-memecoin
```

**Networks:**
- `base` - Base Mainnet (production)
- `base-sepolia` - Base Sepolia (testnet)

**Request:**

```json
{
  "name": "My Awesome Coin",
  "symbol": "MAC",
  "description": "A fun memecoin powered by Flaunch",
  "imageIpfs": "QmX7UbPKJ7Drci3y6p6E8oi5TpUiG7NH3qSzcohPX9Xkvo",
  "websiteUrl": "https://example.com",
  "discordUrl": "https://discord.gg/example",
  "twitterUrl": "https://x.com/example",
  "telegramUrl": "https://t.me/example",
  "creatorAddress": "0x498E93Bc04955fCBAC04BCF1a3BA792f01Dbaa96"
}
```

**Required Fields:**
- `name` - Token name (max 32 characters)
- `symbol` - Token symbol (max 10 characters)
- `imageIpfs` - IPFS hash from upload-image
- `creatorAddress` - Address to receive the ERC721 ownership NFT

**Optional Fields:**
- `description` - Token description
- `websiteUrl` - Project website
- `discordUrl` - Discord invite link
- `twitterUrl` - Twitter/X profile
- `telegramUrl` - Telegram group link

**Response:**

```json
{
  "success": true,
  "message": "Memecoin launch request queued",
  "jobId": "23209",
  "queueStatus": {
    "position": 0,
    "waitingJobs": 0,
    "activeJobs": 1,
    "estimatedWaitSeconds": 0
  },
  "privy": {
    "type": "wallet",
    "address": "0x498E93Bc04955fCBAC04BCF1a3BA792f01Dbaa96"
  }
}
```

---

### Check Launch Status

Check the status of a launch job.

```
GET /api/v1/launch-status/{jobId}
```

**Response (pending):**

```json
{
  "success": true,
  "state": "waiting",
  "queuePosition": 2,
  "estimatedWaitTime": 120
}
```

**Response (completed):**

```json
{
  "success": true,
  "state": "completed",
  "queuePosition": 0,
  "estimatedWaitTime": 0,
  "transactionHash": "0xefebe9769e4cb44c40cd5a1785b1f26dc66b47c2d3caa369fb75cad055b89348",
  "collectionToken": {
    "address": "0xe9c1d0294e9507d8913784e888235c9f678f8ee2",
    "imageIpfs": "QmQWinjqfyqhdQZrsaL95DyJ8ozYwg1MgjnHmimvz36B8b",
    "name": "My Awesome Coin",
    "symbol": "MAC",
    "tokenURI": "ipfs://QmRwn8gbQgCYDWoWyeJW9R6z3tNmLKngR7w7G3AZuoD9GH",
    "creator": "0x498E93Bc04955fCBAC04BCF1a3BA792f01Dbaa96"
  }
}
```

**Job States:**
- `waiting` - In queue
- `active` - Currently processing
- `completed` - Successfully launched
- `failed` - Launch failed

---

## Default Parameters

Tokens launched via the gasless API use these defaults:

| Parameter | Value |
|-----------|-------|
| Starting market cap | $10,000 USD |
| Creator fee allocation | 20% |
| Protocol fees | None |

---

## Error Responses

```json
{
  "success": false,
  "error": "Error message here"
}
```

**Common Errors:**
- `Content flagged` - Image failed NSFW check
- `Invalid image format` - Unsupported image type
- `Rate limit exceeded` - Too many requests
- `Invalid creator address` - Malformed Ethereum address
