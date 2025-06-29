// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Script, console} from "forge-std/Script.sol";
import {EIP1967Proxy} from "../contracts/proxy/Proxy.sol";

/**
 * @title DeployEIP1967Proxy
 * @notice Deploys the EIP1967Proxy contract.
 * @dev Replace placeholder addresses before running.
 */
contract DeployEIP1967Proxy is Script {
    function run() external returns (EIP1967Proxy proxy) {
        // --- Configuration --- //

        // !!! IMPORTANT: Replace with the actual address of your logic contract (e.g., PeridotHub, PeridotSpoke)
        address initialImplementation = address(
            0x2795Bd7AEaA3aE6b2186D4b82240e21068777Fbb
        );

        // !!! IMPORTANT: Replace with the desired admin address for the proxy
        // address initialAdmin = vm.envAddress("PROXY_ADMIN"); // Example: Load from .env file
        address initialAdmin = address(
            0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9
        );

        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_TEST");
        address deployerAddress = vm.addr(deployerPrivateKey);

        // --- Input Validation --- //
        require(
            initialImplementation != address(0),
            "DeployEIP1967Proxy: Initial implementation address cannot be zero. Please replace the placeholder."
        );
        require(
            initialAdmin != address(0),
            "DeployEIP1967Proxy: Initial admin address cannot be zero. Please set PROXY_ADMIN env var or hardcode the address."
        );
        require(
            deployerPrivateKey != 0,
            "DeployEIP1967Proxy: PRIVATE_KEY env var not set."
        );

        console.log("Deploying EIP1967Proxy...");
        console.log("  Deployer:", deployerAddress);
        console.log("  Initial Implementation:", initialImplementation);
        console.log("  Initial Admin:", initialAdmin);

        // --- Deployment --- //
        vm.startBroadcast(deployerPrivateKey);

        proxy = new EIP1967Proxy(initialImplementation, initialAdmin);

        vm.stopBroadcast();

        // --- Output --- //
        console.log("\nEIP1967Proxy deployed successfully!");
        console.log("  Proxy Address:", address(proxy));
        console.log("  Implementation Address (set):", proxy.implementation());
        console.log("  Admin Address (set):", proxy.admin());
    }
}
