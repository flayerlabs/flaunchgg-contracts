# Custom Managers Reference

Build your own treasury manager for custom fee distribution logic.

## Base Contracts

Two base contracts are available:

| Contract | Use Case |
|----------|----------|
| `TreasuryManager` | Full control, implement everything |
| `FeeSplitManager` | Pre-built split logic, customize distribution |

---

## TreasuryManager Base Contract

The base `TreasuryManager` contract provides core functionality. Override these internal methods:

```solidity
abstract contract TreasuryManager {
    
    /// @notice Initialize the manager (called once by factory)
    /// @param _owner Manager owner address
    /// @param _data Encoded initialization parameters
    function _initialize(address _owner, bytes calldata _data) internal virtual;
    
    /// @notice Handle token deposit
    /// @param _flaunchToken The Flaunch token being deposited
    /// @param _creator Address depositing the token
    /// @param _data Additional deposit data
    function _deposit(
        FlaunchToken calldata _flaunchToken, 
        address _creator, 
        bytes calldata _data
    ) internal virtual;
}
```

**Note:** External functions like `balances()` and `claim()` are defined on `ITreasuryManager`. Additional extension hooks are on `FeeSplitManager`.
```

---

## FeeSplitManager Base

Extends `TreasuryManager` with pre-built split logic. Override these methods for custom distribution:

```solidity
abstract contract FeeSplitManager is TreasuryManager {
    
    uint public constant VALID_SHARE_TOTAL = 100_00000;
    
    /// @notice Get claimable balance for recipient
    /// @param _recipient Address to check
    function balances(address _recipient) public view virtual returns (uint);
    
    /// @notice Get recipient's share percentage
    /// @param _recipient Address to check
    /// @param _data Additional context data
    function recipientShare(address _recipient, bytes memory _data) 
        public view virtual returns (uint);
    
    /// @notice Check if recipient can claim
    /// @param _recipient Address to check
    /// @param _data Additional validation data
    function isValidRecipient(address _recipient, bytes memory _data) 
        public view virtual returns (bool);
    
    /// @notice Calculate and record claim amount (internal)
    /// @param _recipient Claiming address
    /// @param _data Additional claim data
    function _captureClaim(address _recipient, bytes memory _data) 
        internal virtual returns (uint);
    
    /// @notice Send fees to recipient (internal)
    /// @param _recipient Receiving address
    /// @param _allocation Amount to send
    /// @param _data Additional dispatch data
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory _data) 
        internal virtual;
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
        uint topSpots;
    }
    
    address[] public leaderboard;
    uint[] public scores;
    uint public topSpots;
    
    // Distribution: top 3 get 50%, 30%, 20%
    uint[3] internal distribution = [uint(50_00000), 30_00000, 20_00000];
    
    function _initialize(address _owner, bytes calldata _data) internal override {
        InitializeParams memory params = abi.decode(_data, (InitializeParams));
        
        _setShares(params.creatorShare, params.ownerShare);
        topSpots = params.topSpots;
        
        leaderboard = new address[](params.topSpots);
        scores = new uint[](params.topSpots);
    }
    
    /// @notice Update leaderboard (only manager owner)
    function updateScore(address player, uint score) external onlyManagerOwner {
        for (uint i = 0; i < topSpots; i++) {
            if (score > scores[i]) {
                // Shift down and insert
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
    
    /// @notice Get recipient's share based on leaderboard position
    function recipientShare(address _recipient, bytes memory) 
        public view override returns (uint) 
    {
        for (uint i = 0; i < topSpots && i < 3; i++) {
            if (leaderboard[i] == _recipient) {
                return distribution[i];
            }
        }
        return 0;
    }
    
    function isValidRecipient(address _recipient, bytes memory _data) 
        public view override returns (bool) 
    {
        return recipientShare(_recipient, _data) > 0;
    }
}
```

---

## Example: Time-Locked Manager

Fees only claimable after a lock period:

```solidity
contract TimeLockManager is FeeSplitManager {
    
    uint public unlockTime;
    
    struct InitializeParams {
        uint creatorShare;
        uint ownerShare;
        uint lockDuration;
        address[] recipients;
        uint[] shares;
    }
    
    /// Track recipient shares
    mapping(address => uint) internal _recipientShares;
    
    /// Track amount claimed per recipient  
    mapping(address => uint) public amountClaimed;
    
    function _initialize(address _owner, bytes calldata _data) internal override {
        InitializeParams memory params = abi.decode(_data, (InitializeParams));
        
        // Use _setShares to properly initialize creator and owner shares
        _setShares(params.creatorShare, params.ownerShare);
        unlockTime = block.timestamp + params.lockDuration;
        
        // Store recipient shares
        uint totalShare;
        for (uint i; i < params.recipients.length; ++i) {
            _recipientShares[params.recipients[i]] = params.shares[i];
            totalShare += params.shares[i];
        }
        
        // Validate shares sum to 100%
        if (totalShare != VALID_SHARE_TOTAL) {
            revert InvalidRecipientShareTotal(totalShare, VALID_SHARE_TOTAL);
        }
    }
    
    function recipientShare(address _recipient, bytes memory) 
        public view override returns (uint) 
    {
        return _recipientShares[_recipient];
    }
    
    function isValidRecipient(
        address _recipient, 
        bytes memory _data
    ) public view override returns (bool) {
        // Only valid if unlock time has passed and recipient has a share
        return block.timestamp >= unlockTime && _recipientShares[_recipient] > 0;
    }
    
    function _captureClaim(address _recipient, bytes memory _data) 
        internal override returns (uint allocation_) 
    {
        // Calculate allocation based on managerFees and recipient share
        uint totalOwed = (managerFees() * _recipientShares[_recipient]) / VALID_SHARE_TOTAL;
        allocation_ = totalOwed - amountClaimed[_recipient];
        amountClaimed[_recipient] = totalOwed;
    }
    
    function _dispatchRevenue(address _recipient, uint _allocation, bytes memory) 
        internal override 
    {
        (bool success, bytes memory data) = payable(_recipient).call{value: _allocation}('');
        if (!success) revert UnableToSendRevenue(data);
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
| Access control | Implement `onlyManagerOwner` modifiers |
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
