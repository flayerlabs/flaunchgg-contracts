// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Contracts
import { CrossDomainMessenger } from "src/universal/CrossDomainMessenger.sol";

// Libraries
import { AddressAliasHelper } from "src/vendor/AddressAliasHelper.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";

// Interfaces
import { ISemver } from "interfaces/universal/ISemver.sol";
import { IL2ToL1MessagePasser } from "interfaces/L2/IL2ToL1MessagePasser.sol";

/// @custom:proxied true
/// @custom:predeploy 0x4200000000000000000000000000000000000007
/// @title L2CrossDomainMessenger
/// @notice The L2CrossDomainMessenger is a high-level interface for message passing between L1 and
///         L2 on the L2 side. Users are generally encouraged to use this contract instead of lower
///         level message passing contracts.
contract L2CrossDomainMessenger is CrossDomainMessenger, ISemver {
    /// @custom:semver 2.2.0
    string public constant version = "2.2.0";

    /// @notice Constructs the L2CrossDomainMessenger contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer.
    /// @param _l1CrossDomainMessenger L1CrossDomainMessenger contract on the other network.
    function initialize(CrossDomainMessenger _l1CrossDomainMessenger) external initializer {
        __CrossDomainMessenger_init({ _otherMessenger: _l1CrossDomainMessenger });
    }

    /// @notice Getter for the remote messenger.
    ///         Public getter is legacy and will be removed in the future. Use `otherMessenger()` instead.
    /// @return L1CrossDomainMessenger contract.
    /// @custom:legacy
    function l1CrossDomainMessenger() public view returns (CrossDomainMessenger) {
        return otherMessenger;
    }

    /// @inheritdoc CrossDomainMessenger
    function _sendMessage(address _to, uint64 _gasLimit, uint256 _value, bytes memory _data) internal override {
        IL2ToL1MessagePasser(payable(Predeploys.L2_TO_L1_MESSAGE_PASSER)).initiateWithdrawal{ value: _value }(
            _to, _gasLimit, _data
        );
    }

    /// @inheritdoc CrossDomainMessenger
    function _isOtherMessenger() internal view override returns (bool) {
        return AddressAliasHelper.undoL1ToL2Alias(msg.sender) == address(otherMessenger);
    }

    /// @inheritdoc CrossDomainMessenger
    function _isUnsafeTarget(address _target) internal view override returns (bool) {
        return _target == address(this) || _target == address(Predeploys.L2_TO_L1_MESSAGE_PASSER);
    }
}
