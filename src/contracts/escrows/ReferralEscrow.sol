// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {ProtocolRoles} from '@flaunch/libraries/ProtocolRoles.sol';
import {PoolSwap} from '@flaunch/zaps/PoolSwap.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';
import {IReferralEscrow} from '@flaunch-interfaces/IReferralEscrow.sol';

/**
 * When a user referrers someone that then actions a swap, their address is passed in the `hookData`. This
 * user will then receive a referral fee of the unspecified token amount. This amount will be moved to this
 * escrow contract to be claimed at a later time.
 */
contract ReferralEscrow is IReferralEscrow, AccessControl, Ownable {
    /// PoolSwap contract for performing swaps
    PoolSwap public poolSwap;

    /// The native token used by the Flaunch protocol
    address public immutable nativeToken;

    /// Mapping to track token allocations by user and token
    mapping(address _user => mapping(address _token => uint _amount)) public allocations;

    /**
     * Constructor to initialize the PoolSwap contract address.
     *
     * @param _nativeToken The native token used by the Flaunch protocol
     * @param _protocolOwner The address of the protocol owner
     */
    constructor(
        address _nativeToken,
        address _protocolOwner
    ) {
        nativeToken = _nativeToken;

        // Set our caller to have the default admin of protocol roles
        _grantRole(DEFAULT_ADMIN_ROLE, _protocolOwner);
        _initializeOwner(_protocolOwner);
    }

    /**
     * Function to update the PoolSwap contract address (only owner can call this).
     *
     * @dev This function is deprecated and will be removed in a future version.
     *
     * @param _poolSwap The new address that will handle pool swaps
     */
    function setPoolSwap(
        address _poolSwap
    ) external onlyOwner {
        poolSwap = PoolSwap(_poolSwap);
    }

    /**
     * Function to assign tokens to a user with a PoolId included in the event.
     *
     * @dev Only an approved {PositionManager} contract can make this call.
     *
     * @param _poolId The PoolId that generated referral fees
     * @param _user The user that received the referral fees
     * @param _token The token that the fees are paid in
     * @param _amount The amount of fees granted to the user
     */
    function assignTokens(
        PoolId _poolId,
        address _user,
        address _token,
        uint _amount
    ) external onlyPositionManager {
        // If no amount is passed, then we have nothing to process
        if (_amount == 0) {
            return;
        }

        allocations[_user][_token] += _amount;
        emit TokensAssigned(_poolId, _user, _token, _amount);
    }

    /**
     * Function for a user to claim tokens across multiple token addresses.
     *
     * @param _tokens The tokens to be claimed by the caller
     */
    function claimTokens(
        address[] calldata _tokens,
        address payable _recipient
    ) external {
        address token;
        uint amount;
        for (uint i; i < _tokens.length; ++i) {
            token = _tokens[i];
            amount = allocations[msg.sender][token];

            // If there is nothing to claim, skip next steps
            if (amount == 0) {
                continue;
            }

            // Update allocation before transferring to prevent reentrancy attacks
            allocations[msg.sender][token] = 0;

            // If we are claiming the native token, then we can unwrap the flETH to ETH
            if (token == nativeToken) {
                // Withdraw the FLETH and transfer the ETH to the caller
                IFLETH(nativeToken).withdraw(amount);
                (bool _sent,) = _recipient.call{value: amount}('');
                require(_sent, 'ETH Transfer Failed');
            }
            // Otherwise, just transfer the token directly to the user
            else {
                IERC20(token).transfer(_recipient, amount);
            }

            emit TokensClaimed(msg.sender, _recipient, token, amount);
        }
    }

    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization.
     *
     * @return bool Set to `true` to prevent owner being reinitialized.
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /**
     * Ensures that only an approved {PositionManager} can call the function.
     */
    modifier onlyPositionManager() {
        if (!hasRole(ProtocolRoles.POSITION_MANAGER, msg.sender)) {
            revert NotPositionManager();
        }
        _;
    }

    /**
     * Allows the contract to receive ETH from the flETH withdrawal.
     */
    receive() external payable {}
}
