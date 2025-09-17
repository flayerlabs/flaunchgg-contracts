// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';

import {CustomFeeManagerRegistry} from '@flaunch/treasury/managers/partners/CustomFeeManagerRegistry.sol';
import {FairLaunch} from '@flaunch/hooks/FairLaunch.sol';

import {ICustomFeeManager} from '@flaunch-interfaces/ICustomFeeManager.sol';
import {IFeeCalculator} from '@flaunch-interfaces/IFeeCalculator.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';


/**
 * Abstract base contract for fee calculators that provides manager override functionality.
 * 
 * This contract allows pool creators (ERC721 owners) to set custom fee calculation managers
 * that can override the default fee calculation logic.
 */
abstract contract BaseFeeCalculator is IFeeCalculator {

    error NotImplemented();

    /// The native token address used by the protocol
    address public immutable nativeToken;

    /// The custom fee manager registry
    CustomFeeManagerRegistry public immutable customFeeManagerRegistry;

    /**
     * Sets the native token and custom fee manager registry.
     *
     * @param _nativeToken The native token address used by the protocol
     * @param _customFeeManagerRegistry The custom fee manager registry address
     */
    constructor (address _nativeToken, address _customFeeManagerRegistry) {
        nativeToken = _nativeToken;
        customFeeManagerRegistry = CustomFeeManagerRegistry(_customFeeManagerRegistry);
    }

    /**
     * Determines the swap fee, with optional manager override.
     * 
     * @param _poolKey The pool key
     * @param _params The swap parameters
     * @param _baseFee The base fee
     * 
     * @return swapFee_ The calculated swap fee
     */
    function determineSwapFee(
        PoolKey memory _poolKey,
        IPoolManager.SwapParams memory _params,
        uint24 _baseFee
    ) public view returns (uint24 swapFee_) {
        // Check if there's a manager override
        address manager = _getApprovedSwapFeeManager(_poolKey);
        if (manager != address(0)) {
            // Try to call the manager's determineSwapFee function
            try ICustomFeeManager(manager).determineSwapFee(_poolKey, _params, _baseFee) returns (uint24 managerFee) {
                return managerFee;
            } catch {
                // If the manager call fails, fall back to the default implementation
            }
        }

        // Call the default implementation
        return _determineSwapFee(_poolKey, _params, _baseFee);
    }

    /**
     * Tracks swap information, with optional manager override.
     * 
     * @param _sender The sender address
     * @param _poolKey The pool key
     * @param _params The swap parameters
     * @param _delta The balance delta
     * @param _hookData The hook data
     */
    function trackSwap(
        address _sender,
        PoolKey calldata _poolKey,
        IPoolManager.SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) public {
        // Check if there's a manager override
        address manager = _getApprovedSwapFeeManager(_poolKey);
        if (manager != address(0)) {
            // Try to call the manager's trackSwap function
            try ICustomFeeManager(manager).trackSwap(_sender, _poolKey, _params, _delta, _hookData) returns (bool bypassNative_) {
                // If the manager bypasses the native logic, we return early
                if (bypassNative_) return;
            } catch {
                // If the manager call fails, fall back to the default implementation
            }
        }

        // Call the default implementation
        _trackSwap(_sender, _poolKey, _params, _delta, _hookData);
    }

    /**
     * Sets flaunch parameters.
     * 
     * @param _poolId The pool ID
     * @param _params The flaunch parameters
     */
    function setFlaunchParams(PoolId _poolId, bytes calldata _params) external virtual override {
        _setFlaunchParams(_poolId, _params);
    }

    /**
     * Gets the pool creator (ERC721 owner) for a given pool key.
     * 
     * @param _poolKey The pool key
     * @return approvedManager_ The approved manager address
     */
    function _getApprovedSwapFeeManager(PoolKey memory _poolKey) internal view returns (address approvedManager_) {
        // Find the memecoin address from the pool key
        address memecoinAddress;
        if (nativeToken == Currency.unwrap(_poolKey.currency0)) {
            memecoinAddress = Currency.unwrap(_poolKey.currency1);
        } else if (nativeToken == Currency.unwrap(_poolKey.currency1)) {
            memecoinAddress = Currency.unwrap(_poolKey.currency0);
        } else {
            return address(0);
        }

        // Get the creator from the memecoin contract
        approvedManager_ = IMemecoin(memecoinAddress).creator();
        if (!customFeeManagerRegistry.isApprovedManager(approvedManager_)) {
            return address(0);
        }
    }

    /**
     * Abstract function for the default swap fee calculation.
     * 
     * @param _poolKey The pool key
     * @param _params The swap parameters
     * @param _baseFee The base fee
     * 
     * @return swapFee_ The calculated swap fee
     */
    function _determineSwapFee(
        PoolKey memory _poolKey,
        IPoolManager.SwapParams memory _params,
        uint24 _baseFee
    ) internal view virtual returns (uint24 swapFee_) {
        revert NotImplemented();
    }

    /**
     * Abstract function for the default swap tracking.
     * 
     * @param _sender The sender address
     * @param _poolKey The pool key
     * @param _params The swap parameters
     * @param _delta The balance delta
     * @param _hookData The hook data
     */
    function _trackSwap(
        address _sender,
        PoolKey calldata _poolKey,
        IPoolManager.SwapParams calldata _params,
        BalanceDelta _delta,
        bytes calldata _hookData
    ) internal virtual {
        // ..
    }

    /**
     * Abstract function for the default flaunch parameter setting.
     * 
     * @param _poolId The pool ID
     * @param _params The flaunch parameters
     */
    function _setFlaunchParams(PoolId _poolId, bytes calldata _params) internal virtual {
        // ..
    }

    /**
     * Helper function to check if the pool is in fair launch.
     * 
     * @param _positionManager The position manager
     * @param _poolId The pool ID
     */
    function _isInFairLaunch(address _positionManager, PoolId _poolId) internal virtual returns (bool isInFairLaunch_) {
        // Get the fair launch information for the pool
        PoolId poolId = _poolId;

        // Get the fair launch information to check if it ended at the current block timestamp
        FairLaunch.FairLaunchInfo memory fairLaunchInfo = IPositionManager(_positionManager).fairLaunch().fairLaunchInfo(poolId);
        
        // If the fair launch ended at the same timestamp as the current block, we need to
        // verify the transaction using the fair launch calculator
        return fairLaunchInfo.endsAt <= block.timestamp;
    }

}
