// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {WETHHook} from "../../../src/WETHHook.sol";

/// @notice Mines the address and deploys the WETHHook.sol Hook contract on Arbitrum
contract DeployWETHHookArbitrumScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    IPoolManager constant POOLMANAGER = IPoolManager(address(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32));
    address payable public constant WETH_ADDRESS = payable(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

    function setUp() public {}

    function run() public {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(POOLMANAGER, WETH_ADDRESS);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WETHHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        WETHHook wethHook = new WETHHook{salt: salt}(POOLMANAGER, WETH_ADDRESS);
        require(address(wethHook) == hookAddress, "WETHHookScript: hook address mismatch");

        console2.log("WETHHook deployed to:", address(wethHook));
    }
}
