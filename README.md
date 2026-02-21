# Flaunch Protocol - README
## Overview
The Flaunch protocol is an innovative platform designed to revolutionize the way memecoins are launched and traded. With a focus on creating sustainable "meme economies," the Flaunch protocol introduces features that ensure a fair, transparent, and risk-free launch environment for all participants, from developers to traders. By integrating mechanisms like Progressive Bid Walls and decentralized revenue-sharing models, Flaunch aligns the incentives of all stakeholders towards long-term success rather than short-term gains.

## Key Features
1. **Buyback and Bid Wall**:
   - Trading fees are allocated towards buybacks through Progressive Bid Walls, which start just below the current spot price and adjust upward as the price increases. This mechanism helps stabilize the coin's value and ensures continuous market activity.

2. **Meme Economies**:
   - Coin holders have the power to halt Progressive Bid Walls and instead accumulate revenue in a treasury. This treasury can be utilized in ways determined by the token holders, fostering a community-driven economy.

3. **Devs Get Revs**:
   - Developers, known as "flaunchers," receive a percentage of all trading fees. This aligns their incentives with the long-term health of the memecoin, encouraging them to focus on sustainable growth rather than quick pumps and dumps. Dev Revs are always converted to our ETH equivalent token (flETH) using our Internal Swap Pool. This means no negative token dumps to get fees.

4. **Risk-Free Fair Launch**:
   - During the initial fair launch period, all ETH proceeds are funneled back into a Progressive Bid Wall. This allows early buyers to exit at their entry price (minus the AMM fee), ensuring that no party has an unfair advantage, and guaranteeing a fair launch for all participants.

## Why Flaunch?
Memecoin launchpads have traditionally been extractive, often benefitting Key Opinion Leaders (KOLs), MEV operators, and even validators at the expense of the broader community. The Flaunch protocol seeks to disrupt this model by creating an environment where launching a coin is not only fun and fair but also gives users a better chance of profit. By enabling the formation of true "meme economies" and rewarding developers through revenue sharing, Flaunch offers a fresh, degen-centric approach to memecoin launches.

## Getting Started
To start using the Flaunch protocol, please refer to our [documentation](https://docs.flaunch.gg/flaunch-docs) which provides detailed instructions on setting up, launching, and managing your memecoin within the Flaunch ecosystem.

For further assistance, feel free to reach out to our team through our official communication channels.

## Contracts
### Flaunch Addresses
| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| FeeExemptions         | `0xfdCE459071c74b732B2dEC579Afb38Ea552C4e06` | `0xD0aa3724074727629A9794d8A06CA1B2aDb51a85` |
| MarketCappedPrice     | `0xf318e170d10a1f0d9b57211e908a7f081123e7f6` | `0xe8f624a3fd5b3ae3914baac21f9fd636259f57f2` |
| PositionManager       | `0x23321f11a6d44fd1ab790044fdfde5758c902fdc` | `0x4e7cb1e6800a7b297b38bddcecaf9ca5b6616fdc` |
| BidWall               | `0x7f22353d1634223a802d1c1ea5308ddf5dd0ef9c` | `0x6f2fa01a05ff8b6efbfefd91a3b85aaf19265a00` |
| FairLaunch (Deprecated) | `[Deprecated]`                               | `[Deprecated]`                               |
| TreasuryActionManager | `0xfb5c20c4e60c9c64648dd3692437e3e313add4a4` | `0xc5299fb5c8ccad97fb74f9f346337d9e00c319ca` |
| Notifier              | `0x75a8264b748147fdbfAE518CF37Fd3A83FC03aB7` | `0xCc4B78FBACFD16b0beFd742b163185f9671d01A6` |
| Memecoin              | `0xF1EEeeeeECd95E9Eb2df58484ceed175AcBD945C` | `0x08D9f2512da858fB9DbEaFb62EE9F5F5a3519367` |
| MemecoinTreasury      | `0x7397390360bd9d559d9277e60d47b99933791232` | `0x89ac06abf75752c961f6b3b44b699ec03f5f123c` |
| Flaunch               | `0x516af52d0c629b5e378da4dc64ecb0744ce10109` | `0xe2ef58a54ee79dac0d4a130ea58b340124df9438` |
| StaticFeeCalculator   | `0xaA27191eB96F8C9F1f50519C53e6512228f2faB9` | `0x8FCedC6bf6bd2691CA9efd9E41Ff01ef325585e0` |
| BuyBackAction         | `0xDa4866c97E3414b920663041C680012D6Ee296bE` | `0xb480B22fE3a802526c2C2533535ddB8DA6694Aec` |
| BurnTokensAction      | `0x8696a1F26e678D15c251f07556696b877D3382c8` | `0xe8c3A9428aA97A8Cef5DF45af7d6Af7d553dd92c` |
| FlaunchPremineZap     | `0xeFA8267954b0740dC981a40D8E23d07116c8DfFE` | `0xb84d6cc0cC54A1a30dF07e4B869Cc4AFa7405281` |
| FlaunchZap            | `0xa9bd947751c6a6d33ccd0ef4a03c48466f24c172` | `0x25b747aeca2612b9804b5c3bb272a3daefdc6eaa` |
| ReferralEscrow        | `0xd381f8ea57df43c57cfe6e5b19a0a4700396f28c` | `0xd3d9047cabe3346c70b510435866565176e8ce12` |
| PoolSwap              | `0xdcf8e5e2a21e9b7e37b1b1a6612f1376723dd08e` | `0x9ef9762c55275b1ba8b6b900fa4c3a349f581014` |

### flETH Addresses
| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| flETH                 | `0x000000000d564d5be76f7f0d28fe52605afc7cf8` | `0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb` |
| FlAaveV3WethGateway   | `0x344e4d19c851b317bb65d31bb5c4e3815b53d727` | `0xed5fEec571D132AeA6D6a636c683b818b3442888` |
| AaveV3Strategy        | `0xd93855bab40a80df2f8ccaae079f2b73d5ec8527` | `0xd5f7Fe1954C5c772Dd562CbcF1e26a6D75Bc0351` |
| flETHHooks            | `0x9e433f32bb5481a9ca7dff5b3af74a7ed041a888` | `0x009941e51253244349c6034761382b01f06dBA99` |

### Uniswap V4 Addresses
| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| PoolManager           | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| PositionDescriptor    | `0x176690c5819A05123b3cD80bd4AA2846cD347489` | `0x33E61BCa1cDa979E349Bf14840BD178Cc7d0F55D` |
| ProxyAdmin            | `0x9B95aF8b4C29346722235D74Da8Fc5E9E3232Eb3` | `[Unknown]`                                  |
| PositionManager       | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` | `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` |
| Quoter                | `0x0d5e0F971ED27FBfF6c2837bf31316121532048D` | `0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa` |
| StateView             | `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71` | `0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4` |
| UniversalRouter       | `0x6fF5693b99212Da76ad316178A184AB56D299b43` | `0x492E6456D9528771018DeB9E87ef7750EF184104` |

## Project Setup
We use [Foundry](https://book.getfoundry.sh/) for tests and deployment. Refer to installation instructions for foundry [here](https://github.com/foundry-rs/foundry#installation).

```sh
git clone https://github.com/flayerlabs/flaunchgg-contracts.git
cd flaunchgg-contracts
forge install
```

Copy `.env.sample` into `.env` and fill out the env variables.

### Tests

```sh
forge test
```

---

This README serves as a high-level introduction to the Flaunch protocol. For more technical details, refer to the linked documentation and resources.
