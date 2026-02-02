# Custom Managers Reference

Build your own treasury manager for custom fee distribution logic.

## Base Contracts

Two base contracts are available:

| Contract | Use Case |
|----------|----------|
| `TreasuryManager` | Full control, implement everything |
| `FeeSplitManager` | Pre-built split logic, customize distribution |

---

## TreasuryManager Interface

```solidity
abstract contract TreasuryManager {
    
    /// @notice Initialize the manager
    /// @param _owner Manager owner address
    /// @param _data Encoded initialization parameters
    function _initialize(address _owner, bytes calldata _data) internal virtual;
    
    /// @notice Handle token deposit
    /// @param token The Flaunch token being deposited
    /// @param creator Address depositing the token
    /// @param data Additional deposit data
    function _deposit(
        FlaunchToken calldata token, 
        address creator, 
        bytes calldata data
    ) internal virtual;
    
    /// @notice Get claimable balance for recipient
    /// @param recipient Address to check
    /// @return Claimable amount in wei
    function balances(address recipient) public view virtual returns (uint);
    
    /// @notice Check if address can claim
    /// @param recipient Address to check
    /// @param data Additional validation data
    /// @return True if recipient can claim
    function isValidRecipient(
        address recipient, 
        bytes memory data
    ) public view virtual returns (bool);
    
    /// @notice Calculate and record claim amount
    /// @param recipient Claiming address
    /// @param data Additional claim data
    /// @return Amount being claimed
    function _captureClaim(
        address recipient, 
        bytes memory data
    ) internal virtual returns (uint);
    
    /// @notice Send fees to recipient
    /// @param recipient Receiving address
    /// @param allocation Amount to send
    /// @param data Additional dispatch data
    function _dispatchRevenue(
        address recipient, 
        uint allocation, 
        bytes memory data
    ) internal virtual;
}
```

---

## FeeSplitManager Base

Extends `TreasuryManager` with pre-built split logic:

```solidity
abstract contract FeeSplitManager is TreasuryManager {
    
    uint public creatorShare;    // 5 decimals
    uint public ownerShare;      // 5 decimals
    
    /// @notice Override to define custom split recipients
    function _getSplitRecipients() internal view virtual returns (
        address[] memory recipients,
        uint[] memory shares
    );
    
    /// @notice Fees are automatically split per shares
    /// Creator and owner receive their shares first
    /// Remaining goes to _getSplitRecipients()
}
```

---

## Example: Leaderboard Manager

Distribute fees based on a leaderboard:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeSplitManager} from "./FeeSplitManager.sol";

contract LeaderboardManager is FeeSplitManager {
    
    struct InitializeParams {
        uint creatorShare;
        uint ownerShare;
        uint topSpots;           // Number of leaderboard spots
    }
    
    address[] public leaderboard;
    uint[] public scores;
    uint public topSpots;
    
    function _initialize(address _owner, bytes calldata _data) internal override {
        InitializeParams memory params = abi.decode(_data, (InitializeParams));
        
        creatorShare = params.creatorShare;
        ownerShare = params.ownerShare;
        topSpots = params.topSpots;
        
        leaderboard = new address[](params.topSpots);
        scores = new uint[](params.topSpots);
    }
    
    /// @notice Update leaderboard (called by game contract)
    function updateScore(address player, uint score) external onlyOwner {
        // Find position and insert
        for (uint i = 0; i < topSpots; i++) {
            if (score > scores[i]) {
                // Shift down
                for (uint j = topSpots - 1; j > i; j--) {
                    leaderboard[j] = leaderboard[j-1];
                    scores[j] = scores[j-1];
                }
                leaderboard[i] = player;
                scores[i] = score;
                break;
            }
        }
    }
    
    function _getSplitRecipients() internal view override returns (
        address[] memory recipients,
        uint[] memory shares
    ) {
        recipients = new address[](topSpots);
        shares = new uint[](topSpots);
        
        // Top 3 get 50%, 30%, 20% of split share
        uint[3] memory distribution = [uint(50_00000), 30_00000, 20_00000];
        
        for (uint i = 0; i < topSpots && i < 3; i++) {
            recipients[i] = leaderboard[i];
            shares[i] = distribution[i];
        }
        
        return (recipients, shares);
    }
}
```

---

## Example: Time-Locked Manager

Fees only claimable after a lock period:

```solidity
contract TimeLockManager is FeeSplitManager {
    
    uint public unlockTime;
    mapping(address => uint) public pendingClaims;
    
    struct InitializeParams {
        uint creatorShare;
        uint ownerShare;
        uint lockDuration;
        address[] recipients;
        uint[] shares;
    }
    
    address[] internal _recipients;
    uint[] internal _shares;
    
    function _initialize(address _owner, bytes calldata _data) internal override {
        InitializeParams memory params = abi.decode(_data, (InitializeParams));
        
        creatorShare = params.creatorShare;
        ownerShare = params.ownerShare;
        unlockTime = block.timestamp + params.lockDuration;
        _recipients = params.recipients;
        _shares = params.shares;
    }
    
    function isValidRecipient(
        address recipient, 
        bytes memory
    ) public view override returns (bool) {
        return block.timestamp >= unlockTime && balances(recipient) > 0;
    }
    
    function _getSplitRecipients() internal view override returns (
        address[] memory,
        uint[] memory
    ) {
        return (_recipients, _shares);
    }
}
```

---

## Deployment Checklist

1. **Inherit correctly** - Use `TreasuryManager` or `FeeSplitManager`
2. **Implement all virtuals** - Compiler will error if missing
3. **Test on Sepolia** - Deploy and test before mainnet
4. **Verify contract** - Publish source on BaseScan
5. **Audit if handling significant value** - Custom logic = custom risks

---

## Security Considerations

| Risk | Mitigation |
|------|------------|
| Reentrancy | Use checks-effects-interactions pattern |
| Overflow | Use Solidity 0.8+ built-in checks |
| Access control | Implement `onlyOwner` modifiers |
| Locked funds | Ensure claim paths always exist |
| Gas griefing | Limit loops, use pull over push |

---

## Testing

```solidity
// test/MyCustomManager.t.sol
import {Test} from "forge-std/Test.sol";
import {MyCustomManager} from "../src/MyCustomManager.sol";

contract MyCustomManagerTest is Test {
    MyCustomManager manager;
    
    function setUp() public {
        // Deploy and initialize manager
    }
    
    function testClaim() public {
        // Test claim logic
    }
    
    function testEdgeCases() public {
        // Test boundary conditions
    }
}
```

Run tests:

```bash
forge test --match-contract MyCustomManagerTest -vvv
```
