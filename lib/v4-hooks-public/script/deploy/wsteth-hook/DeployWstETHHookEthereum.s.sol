// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {WstETHHook} from "../../../src/WstETHHook.sol";
import {IWstETH} from "../../../src/interfaces/IWstETH.sol";

/// @notice Mines the address and deploys the WstETHHook.sol Hook contract on Ethereum
contract DeployWstETHHookEthereumScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    IPoolManager constant POOLMANAGER = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
    IWstETH public constant WSTETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    function setUp() public {}

    function run() public {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(POOLMANAGER, WSTETH);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(WstETHHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        WstETHHook wstETHHook = new WstETHHook{salt: salt}(POOLMANAGER, WSTETH);
        require(address(wstETHHook) == hookAddress, "WstETHHookScript: hook address mismatch");

        console2.log("WstETHHook deployed to:", address(wstETHHook));
    }
}
