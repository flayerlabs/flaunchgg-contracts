# Treasury Manager Factory Reference

The `TreasuryManagerFactory` deploys and initializes manager contracts.

## Factory Addresses

| Network | Address |
|---------|---------|
| Base Mainnet | `0x48af8b28DDC5e5A86c4906212fc35Fa808CA8763` |
| Base Sepolia | `0xd2f3c6185e06925dcbe794c6574315b2202e9ccd` |

---

## Deploying a Manager

### Function Signature

```solidity
function deployAndInitializeManager(
    address _managerImplementation,
    address _owner,
    bytes calldata _data
) external returns (address payable manager_)
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `_managerImplementation` | Address of the manager implementation contract |
| `_owner` | Address that will own the deployed manager |
| `_data` | ABI-encoded initialization parameters |

**Note:** Permissions are configured separately after deployment via `manager.setPermissions(permissionsContract)`.

---

## Deployment Examples

### AddressFeeSplitManager

```solidity
import {AddressFeeSplitManager} from "./managers/AddressFeeSplitManager.sol";
import {ITreasuryManagerFactory} from "../interfaces/ITreasuryManagerFactory.sol";

// Build recipient shares array
AddressFeeSplitManager.RecipientShare[] memory shares =
    new AddressFeeSplitManager.RecipientShare[](2);
shares[0] = AddressFeeSplitManager.RecipientShare({
    recipient: addr1,
    share: 50_00000   // 50% of split share
});
shares[1] = AddressFeeSplitManager.RecipientShare({
    recipient: addr2,
    share: 50_00000   // 50% of split share
});

// Prepare init data
bytes memory initData = abi.encode(
    AddressFeeSplitManager.InitializeParams({
        creatorShare: 10_00000,
        ownerShare: 5_00000,
        recipientShares: shares
    })
);

// Deploy manager
address manager = treasuryManagerFactory.deployAndInitializeManager(
    addressFeeSplitManagerImpl,  // Implementation address
    msg.sender,                   // Owner
    initData                      // Encoded params
);

// Optionally configure permissions after deployment
// ITreasuryManager(manager).setPermissions(permissionsContract);
```

### StakingManager

```solidity
import {StakingManager} from "./managers/StakingManager.sol";

bytes memory initData = abi.encode(
    StakingManager.InitializeParams({
        stakingToken: tokenAddress,
        minEscrowDuration: 30 days,
        minStakeDuration: 7 days,
        creatorShare: 10_00000,
        ownerShare: 5_00000
    })
);

address manager = treasuryManagerFactory.deployAndInitializeManager(
    stakingManagerImpl,
    msg.sender,
    initData
);
```

---

## TypeScript Deployment

```typescript
import { encodeFunctionData, encodeAbiParameters } from "viem";

// Encode init params
const initParams = encodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "creatorShare", type: "uint256" },
        { name: "ownerShare", type: "uint256" },
        {
          name: "recipientShares",
          type: "tuple[]",
          components: [
            { name: "recipient", type: "address" },
            { name: "share", type: "uint256" },
          ],
        },
      ],
    },
  ],
  [
    {
      creatorShare: BigInt(10_00000),   // 10%
      ownerShare: BigInt(5_00000),      // 5%
      recipientShares: [
        // Recipients share the remaining 85%, and their shares must sum to 100%
        { recipient: "0xAddr1...", share: BigInt(50_00000) },  // 50% of split
        { recipient: "0xAddr2...", share: BigInt(50_00000) },  // 50% of split
      ],
    },
  ]
);

// Call factory (3 arguments: implementation, owner, data)
const txHash = await walletClient.writeContract({
  address: FACTORY_ADDRESS,
  abi: TreasuryManagerFactoryABI,
  functionName: "deployAndInitializeManager",
  args: [
    MANAGER_IMPL_ADDRESS,
    ownerAddress,
    initParams,
  ],
});
```

---

## Manager Implementation Addresses

### Base Mainnet

| Manager | Implementation |
|---------|---------------|
| RevenueManager | `0x1af9B9f168bFd2046f45E0Ce03972864BcE7eE36` |
| AddressFeeSplitManager | `0xf6d8018450109A68acfBCD2523dc43fB31920a7D` |
| StakingManager | `0xa15F92a7C09a7D6ADbc00FF2DB63e414fBFEA193` |

### Base Sepolia

| Manager | Implementation |
|---------|---------------|
| RevenueManager | `0x17E02501dE3e420347e7C5fCAe3AD787C5aea690` |
| AddressFeeSplitManager | `0xf72dcdee692c188de6b14c6213e849982e04069b` |
| StakingManager | `0x8Ea4074c38cA7a596C740DD9E9D7122ea8E78c3c` |
| ERC721OwnerFeeSplitManager | `0xc98a11e6292bbafb8f55e09a3eef44ba1410a142` |

---

## Permissions

Permissions are configured on the deployed manager via `setPermissions()`:

```solidity
// After deploying manager
ITreasuryManager(manager).setPermissions(permissionsContract);
```

| Permission Contract | Behavior |
|---------------------|----------|
| `address(0)` | Open - anyone can deposit |
| `Closed` | Only manager owner can deposit |
| `Whitelisted` | Only whitelisted addresses can deposit |

### Permission Contracts

```solidity
// Closed permissions - only owner
import {Closed} from "./permissions/Closed.sol";

// Whitelisted - specific addresses
import {Whitelisted} from "./permissions/Whitelisted.sol";

// Example: Set closed permissions
manager.setPermissions(address(closedPermissions));
```

---

## Post-Deployment

After deploying a manager:

1. **Verify on BaseScan** (optional but recommended)
2. **Deposit token NFT** to activate fee distribution
3. **Communicate to holders** about fee structure
