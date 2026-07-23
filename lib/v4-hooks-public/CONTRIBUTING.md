# Contributing

For the latest version of this document, see [here](https://github.com/Uniswap/foundry-template/blob/main/CONTRIBUTING.md).

- [Install](#install)
- [Pre-commit Hooks](#pre-commit-hooks)
- [Requirements for merge](#requirements-for-merge)
- [Branching](#branching)
  - [Main](#main)
  - [Dev](#dev)
  - [Feature](#feature)
  - [Audit](#audit)
- [Code Practices](#code-practices)
  - [Code Style](#code-style)
  - [Solidity Versioning](#solidity-versioning)
  - [Interfaces](#interfaces)
  - [NatSpec \& Comments](#natspec--comments)
- [Testing](#testing)
  - [Best Practices](#best-practices)
  - [IR Compilation](#ir-compilation)
  - [Gas Metering](#gas-metering)
- [Deployment](#deployment)
  - [Bytecode Hash](#bytecode-hash)
  - [Monorepo](#monorepo)
- [Dependency Management](#dependency-management)
- [Releases](#releases)

## Install

Follow these steps to set up your local environment for development:

- [Install foundry](https://book.getfoundry.sh/getting-started/installation)
- Install dependencies: `forge install`
- [Install pre-commit](https://pre-commit.com/#installation)
- Install pre commit hooks: `pre-commit install`

## Pre-commit Hooks

Follow the [installation steps](#install) to enable pre-commit hooks. To ensure consistency in our formatting `pre-commit` is used to check whether code was formatted properly and the documentation is up to date. Whenever a commit does not meet the checks implemented by pre-commit, the commit will fail and the pre-commit checks will modify the files to make the commits pass. Include these changes in your commit for the next commit attempt to succeed. On pull requests the CI checks whether all pre-commit hooks were run correctly.
This repo includes the following pre-commit hooks that are defined in the `.pre-commit-config.yaml`:

- `mixed-line-ending`: This hook ensures that all files have the same line endings (LF).
- `format`: This hook uses `forge fmt` to format all Solidity files.
- `doc`: This hook uses `forge doc` to automatically generate documentation for all Solidity files whenever the NatSpec documentation changes. The `script/util/doc_gen.sh` script is used to generate documentation. Forge updates the commit hash in the documentation automatically. To only generate new documentation when the documentation has actually changed, the script checks whether more than just the hash has changed in the documentation and discard all changes if only the hash has changed.
- `prettier`: All remaining files are formatted using prettier.

## Requirements for merge

In order for a PR to be merged, it must pass the following requirements:

- All commits within the PR must be signed
- CI must pass (tests, linting, etc.)
- New features must be merged with associated tests
- Bug fixes must have a corresponding test that fails without the fix
- The PR must be approved by at least one maintainer
  - The PR must be approved by 2+ maintainers if the PR is a new feature or > 100 LOC changed

## Branching

This section outlines the branching strategy of this repo.

### Main

The main branch is supposed to reflect the deployed state on all networks. Only audited code should be merged into main. Squashed commits from dev or feature branches should be merged into the main branch using a regular merge strategy.

### Dev

This is the active development branch. Upon code completion this branch is frozen on an audit branch. PRs into this branch should squash all commits into a single commit. In case of multiple parallel development efforts, each project should have its own dev branch with the naming convention `dev/<project_name>` to ensure work in progress is isolated and does not end up on the main branch.

### Feature

Feature branches should be owned by one responsible developer. The dev branch should be the target of the feature branch. In pre-audit and pre-deployment repositories feature branches may be merged into the main branch directly. Generally, feature branches should be squashed into a single commit before merging.

### Audit

Before an audit, the code should be frozen on a branch dedicated to the audit with the naming convention `audit/<provider>`. Each fix in response to an audit finding should be developed on its own branch. The naming convention for these branches is `audit/<provider>/<issue_number>`. The PR title should include the provider and the issue number at minimum. Sometimes it is desirable to have all of the fixes in a single PR for review. In this case, each fix PR should be included via the `merge` strategy, and the combined PR can be merged into the dev branch via `merge` to preserve the order of the fix commits.

## Code Practices

### Code Style

The repo follows the official [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html). In addition to that, this repo also borrows the following rules from [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/GUIDELINES.md#solidity-conventions):

- Internal or private state variables or functions should have an underscore prefix.

  ```solidity
  contract TestContract {
      uint256 private _privateVar;
      uint256 internal _internalVar;
      function _testInternal() internal { ... }
      function _testPrivate() private { ... }
  }
  ```

- Naming collisions should be avoided using a single trailing underscore.

  ```solidity
  contract TestContract {
      uint256 public foo;

      constructor(uint256 foo_) {
        foo = foo_;
      }
  }
  ```

- Events should generally be emitted immediately after the state change that they
  represent, and should be named in the past tense. Some exceptions may be made for gas
  efficiency if the result doesn't affect observable ordering of events.

  ```solidity
  function _burn(address who, uint256 value) internal {
      super._burn(who, value);
      emit TokensBurned(who, value);
  }
  ```

- Interface names should have a capital I prefix.

  ```solidity
  interface IERC777 {
  ```

- Contracts not intended to be used standalone should be marked abstract
  so they are required to be inherited to other contracts.

  ```solidity
  abstract contract AccessControl is ..., {
  ```

- Unchecked arithmetic blocks should contain comments explaining why overflow is guaranteed not to happen or permissible. If the reason is immediately apparent from the line above the unchecked block, the comment may be omitted.

### Solidity Versioning

Contracts that are meant to be deployed MUST have an explicit version set in the `pragma` statement.

```solidity
pragma solidity 0.8.X;
```

Abstract contracts, libraries and interfaces MUST use the caret (`^`) range operator to specify the version range to ensure better compatibility.

```solidity
pragma solidity ^0.X.0;
```

Libraries and abstract contracts using functionality introduced in newer versions of Solidity can use caret range operators with higher path versions (e.g., `^0.8.24` when using transient storage opcodes). For interfaces, it should be considered to use the greater than or equal to (`>=`) range operator to ensure better compatibility with future versions of Solidity.

### Interfaces

Every contract MUST implement their corresponding interface that includes all externally callable functions, errors and events.

### NatSpec & Comments

Interfaces should be the entrypoint for all contracts. When exploring the a contract within the repository, the interface MUST contain all relevant information to understand the functionality of the contract in the form of NatSpec comments. This includes all externally callable functions, errors and events. The NatSpec documentation MUST be added to the functions, errors and events within the interface. This allows a reader to understand the functionality of a function before moving on to the implementation. The implementing functions MUST point to the NatSpec documentation in the interface using `@inheritdoc`. Internal and private functions shouldn't have NatSpec documentation except for `@dev` comments, whenever more context is needed. Additional comments within a function should only be used to give more context to more complex operations, otherwise the code should be kept readable and self-explanatory. Single line NatSpec comments should use a triple slash (`///`) to ensure compact documentation.

## Testing

The following testing practices should be followed when writing unit tests for new code. All functions, lines and branches should be tested to result in 100% testing coverage. Fuzz parameters and conditions whenever possible. Extremes should be tested in dedicated edge case and corner case tests. Invariants should be tested in dedicated invariant tests.

Differential testing should be used to compare assembly implementations with implementations in Solidity or testing alternative implementations against existing Solidity or non-Solidity code using ffi.

New features must be merged with associated tests. Bug fixes should have a corresponding test that fails without the bug fix.

### Best Practices

Best practices and naming conventions should be followed as outlined in the [Foundry Book](https://getfoundry.sh/forge/tests/overview).

### IR Compilation

When the contracts are compiled via IR, tests should be compiled without IR and the contracts deployed from their bytecode to ensure quick compilation times and bytecode consistency. Check [here](https://github.com/Uniswap/foundry-template/blob/613f81c107cd2885a869dbe4afc1da4f96ed9218/foundry.toml#L22-L28) and [here](https://github.com/Uniswap/foundry-template/blob/main/test/deployers/CounterDeployer.sol) for an example.

### Gas Metering

Gas for function calls should be metered using the built in `vm.snapshotGasLastCall` function in forge. To meter across multiple calls `vm.startSnapshotGas` and `vm.stopSnapshotGas` can be used. Tests that measure gas should be annotated with `/// forge-config: default.isolate = true` and not be fuzzed to ensure that the gas snapshot is accurate and consistent for CI verification. All external functions should have a gas snapshot test, diverging paths within a function should have appropriate gas snapshot tests.
For more information on gas metering see the [Forge cheatcodes reference](https://getfoundry.sh/reference/cheatcodes/gas-snapshots/#snapshotgas-cheatcodes).

## Deployment

After deployments are executed a script is provided that extracts deployment information from the `run-latest.json` file within the `broadcast` directory generated while the forge script runs. From this information a JSON and markdown file is generated using the [Forge Chronicles](https://github.com/uniswap/forge-chronicles) library containing various information about the deployment itself as well as past deployments.

### Bytecode Hash

Bytecode hash MUST be set to `none` in the `foundry.toml` file to ensure that the bytecode is consistent.

### Monorepo

Contracts should be integrated into the [Smart Contract Monorepo](https://github.com/uniswap/contracts) to be deployed via the deployer cli tool.

## Dependency Management

The preferred way to manage dependencies is using [`forge install`](https://book.getfoundry.sh/forge/dependencies). This ensures that your project uses the correct versions and structure for all external libraries.

However, in cases where there is a Solidity version mismatch between your project and a dependency, it may be required to include the compiled bytecode directly in a utility contract. This approach allows to deploy the dependency using the correct bytecode, regardless of source compatibility. This may be especially helpful for integration testing.

First, it should be checked if the deployer is already part of [Briefcase](https://github.com/Uniswap/briefcase/tree/main/src/deployers). If so, import the deployer from here.

Otherwise, a custom deploy contract should be created. Below is an example of how to deploy a contract using hardcoded bytecode and the `CREATE2` opcode.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
contract BytecodeDeployer {
    /// @dev Deploys a contract using CREATE2 with the provided bytecode and salt.
    /// @param bytecode The contract bytecode to deploy.
    /// @param salt The salt to use for CREATE2.
    /// @return addr The address of the deployed contract.
    function deploy(bytes memory bytecode, bytes32 salt) public returns (address addr) {
        require(bytecode.length != 0, "Bytecode is empty");
        assembly {
            addr := create2(bytecode, salt)
            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
    }
}
```

## Releases

Every deployment and changes made to contracts after deployment should be accompanied by a tag and release on GitHub.
