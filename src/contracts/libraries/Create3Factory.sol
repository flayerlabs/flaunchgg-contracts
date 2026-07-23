// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CREATE3} from '@solady/utils/CREATE3.sol';

/**
 * Deploys contracts to addresses that depend only on (factory, sender, salt) — never on the
 * contract's init code. Deploying with the same salt from the same sender therefore yields the
 * same address on every chain, even when constructor arguments differ per chain. This is the
 * property needed to pin the Uniswap V4 hook addresses cross-chain, where the init code
 * necessarily embeds chain-specific addresses (PoolManager, flETH); see {FreshChainDeployment}.
 *
 * Salts are namespaced by msg.sender, so an address mined against one sender cannot be squatted
 * by a third party on a chain that has not been deployed to yet.
 */
contract Create3Factory {

    /**
     * Deploys `_initCode` via CREATE3 at the address returned by `predict(_salt, msg.sender)`.
     * Reverts if that address is already occupied (same sender + salt reused).
     *
     * @param _salt The sender-scoped salt that determines the deployment address
     * @param _initCode The contract creation code, including encoded constructor args
     *
     * @return deployed_ The deployed contract address
     */
    function deploy(bytes32 _salt, bytes calldata _initCode) external payable returns (address deployed_) {
        deployed_ = CREATE3.deployDeterministic(msg.value, _initCode, _guard(_salt, msg.sender));
    }

    /**
     * Predicts the address that `deploy` will produce for a (salt, sender) pair. Pure function
     * of the pair and this factory's address — the init code plays no part.
     *
     * @param _salt The sender-scoped salt that determines the deployment address
     * @param _sender The account that would call `deploy`
     *
     * @return deployed_ The address that the deployment would land at
     */
    function predict(bytes32 _salt, address _sender) public view returns (address deployed_) {
        deployed_ = CREATE3.predictDeterministicAddress(_guard(_salt, _sender));
    }

    /**
     * Namespaces a salt by the sender that may deploy with it.
     */
    function _guard(bytes32 _salt, address _sender) internal pure returns (bytes32 guarded_) {
        guarded_ = keccak256(abi.encodePacked(_sender, _salt));
    }
}
