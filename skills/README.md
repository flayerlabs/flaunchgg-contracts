# Flaunch Skills for AI Agents

This directory contains skills that enable AI agents to interact with the Flaunch protocol.

## Available Skills

| Skill | Description |
|-------|-------------|
| [token-launching](./token-launching/) | Launch memecoins on Base via gasless API or SDK |
| [treasury-managers](./treasury-managers/) | Configure fee distribution with treasury managers |

## Quick Start

### Launch a Token (Simplest Path)

```bash
# 1. Upload image
curl -X POST https://web2-api.flaunch.gg/api/v1/upload-image \
  -H "Content-Type: application/json" \
  -d '{"base64Image": "data:image/png;base64,..."}'

# 2. Launch on Base
curl -X POST https://web2-api.flaunch.gg/api/v1/base/launch-memecoin \
  -H "Content-Type: application/json" \
  -d '{
    "name": "My Token",
    "symbol": "TOKEN",
    "imageIpfs": "Qm...",
    "creatorAddress": "0x..."
  }'
```

### Control Fee Distribution

Use treasury managers to program how trading fees are distributed:

- **AddressFeeSplitManager** - Split fees between addresses
- **StakingManager** - Distribute fees to stakers
- **BuyBackManager** - Route fees to token buybacks

See [treasury-managers](./treasury-managers/) for details.

## Resources

- **Flaunch App**: https://flaunch.gg
- **Testnet**: https://testnet.flaunch.gg
- **Documentation**: https://docs.flaunch.gg
- **SDK**: `npm install @flaunch/sdk viem`
