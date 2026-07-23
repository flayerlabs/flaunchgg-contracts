## Uniswap V4 Hooks

This repository contains the official Uniswap v4 hook contracts developed and maintained by Uniswap Labs. New hooks will be added to this repository as they are built and audited.

## Table of Contents

- [Overview](#overview)
- [Hooks](#hooks)
- [Installation](#installation)
- [Deployments](#deployments)
- [Audits](#audits)
- [Docs](#docs)
- [Contributing](#contributing)
- [License](#license)

## Overview

[Hooks](https://docs.uniswap.org/contracts/v4/concepts/hooks) are external contracts that can be attached to Uniswap V4 pools to customize their behavior at key points in the pool lifecycle. This repository houses all Uniswap hook implementations built on top of v4-core.

## Hooks

<details>
<summary><a href="src/WETHHook.sol">WETHHook</a></summary>

A hook for wrapping ETH to WETH and unwrapping WETH to ETH through a Uniswap v4 pool at a 1:1 rate with zero fees.

</details>

<details>
<summary><a href="src/WstETHHook.sol">WstETHHook</a></summary>

A hook for wrapping stETH to wstETH and unwrapping wstETH to stETH through a Uniswap v4 pool. Handles the dynamic exchange rate between stETH and wstETH, accounting for accrued staking rewards and rebasing rounding errors.

</details>

<details>
<summary><a href="src/WstETHRoutingHook.sol">WstETHRoutingHook</a></summary>

A companion hook to `WstETHHook` that enables swap simulation via the V4 Quoter. Since the `WstETHHook` requires actual token deposits that aren't present during simulation, this hook calculates the expected wrapping output without executing the actual token transfers.

</details>

## Installation

```bash
forge install
forge build
forge test --isolate
```

## Deployments

### WETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x57991106cb7aa27e2771beda0d6522f68524a888 | c797b9e     |
| Unichain | 0x730b109bad65152c67ecc94eb8b0968603dba888 | c797b9e     |
| Optimism | 0x480dafdb4d6092ef3217595b75784ec54b52e888 | c797b9e     |
| Base     | 0xb08211d57032dd10b1974d4b876851a7f7596888 | c797b9e     |
| Arbitrum | 0x2a4adf825bd96598487dbb6b2d8d882a4eb86888 | c797b9e     |
| Monad    | 0x3fad8a7205f943528915e67cf94fc792c8fce888 | efab318     |

### WstETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0xcdde8f9c3414a00f804e5c565eed9949ad17e888 | 320811c     |

### WstETHRoutingHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x3ac6e14a142251eb3fe739399e0a8da81ed06888 | 320811c     |

## Audits

| Name       | Date       | Report                                                                   |
| ---------- | ---------- | ------------------------------------------------------------------------ |
| WETHHook   | 04/24/2025 | [OpenZeppelin](./docs/audits/Uniswap_V4_WETH_and_WstETH_Hooks_Audit.pdf) |
| WstETHHook | 04/24/2025 | [OpenZeppelin](./docs/audits/Uniswap_V4_WETH_and_WstETH_Hooks_Audit.pdf) |

### Security Contact

[security@uniswap.org](mailto:security@uniswap.org)

## Docs

The documentation and architecture diagrams for the contracts within this repo can be found [here](docs/).
Detailed documentation generated from the NatSpec documentation of the contracts can be found [here](docs/autogen/src/src/).
When exploring the contracts within this repository, it is recommended to start with the interfaces first and then move on to the implementation as outlined [here](CONTRIBUTING.md#natspec--comments).

## Repository Structure

All contracts are located in the `src/` directory. `test/` contains unit and fork tests for the hook contracts.

```
src/
----base/
|   BaseHook.sol
|   BaseTokenWrapperHook.sol
----interfaces/
|   IWstETH.sol
----utils/
|   HookMiner.sol
----WETHHook.sol
----WstETHHook.sol
----WstETHRoutingHook.sol
test/
----mocks/
----shared/
----WETHHook.t.sol
----WstETHHook.t.sol
----WstETHHook.fork.t.sol
```

## Contributing

If you want to contribute to this project, please check [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

The contracts are covered under the MIT License (`MIT`), see [LICENSE](LICENSE).
