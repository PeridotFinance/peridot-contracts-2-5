// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {TieredPaymaster} from "../contracts/TieredPaymaster.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployTieredPaymasterProxy
 * @dev Deploys an upgradeable TieredPaymaster contract using a TransparentUpgradeableProxy.
 *
 * Usage: forge script script/DeployTieredPaymasterProxy.s.sol:DeployTieredPaymasterProxy --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 */
contract DeployTieredPaymasterProxy is Script {
    // === CONFIGURATION ===
    // Replace with your actual addresses
    address constant COMPOUND_FORK_ADDRESS =
        0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54; // TODO: Replace with actual address
    address constant SIMPLE_PRICE_ORACLE_ADDRESS =
        0xBfEaDDA58d0583f33309AdE83F35A680824E397f;
    address constant TREASURY_ADDRESS =
        0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;
    address constant NATIVE_ASSET_WRAPPER_ADDRESS =
        0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // TODO: e.g., WBNB on BSC
    address constant ENTRY_POINT_ADDRESS =
        0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789; // Standard EntryPoint

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the implementation contract
        console.log("Deploying TieredPaymaster implementation...");
        TieredPaymaster implementation = new TieredPaymaster();
        console.log("Implementation deployed at:", address(implementation));

        // 2. Deploy the ProxyAdmin
        console.log("Deploying ProxyAdmin...");
        ProxyAdmin proxyAdmin = new ProxyAdmin(deployer);
        console.log("ProxyAdmin deployed at:", address(proxyAdmin));

        // 3. Prepare the initialization call
        bytes memory initData = abi.encodeWithSelector(
            TieredPaymaster.initialize.selector,
            ENTRY_POINT_ADDRESS,
            COMPOUND_FORK_ADDRESS,
            SIMPLE_PRICE_ORACLE_ADDRESS,
            TREASURY_ADDRESS,
            NATIVE_ASSET_WRAPPER_ADDRESS,
            deployer // Set the deployer as the initial owner
        );

        // 4. Deploy the TransparentUpgradeableProxy
        console.log("Deploying TransparentUpgradeableProxy...");
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        console.log(
            "Upgradeable TieredPaymaster proxy deployed at:",
            address(proxy)
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Paymaster Implementation:", address(implementation));
        console.log("ProxyAdmin:", address(proxyAdmin));
        console.log("Paymaster Proxy:", address(proxy));
        console.log("Proxy Owner (Admin):", deployer);
        console.log("Initial Owner:", deployer);

        // Note: Verification can be done separately after deployment
        console.log("\n=== Verification ===");
        console.log("To verify deployment, interact with the proxy at:", address(proxy));

        console.log("\n=== Next Steps ===");
        console.log("1. Verify proxy ownership is properly set");
        console.log("2. Fund the paymaster with ETH for gas sponsorship");
        console.log("3. Test with sample UserOperations");
        console.log("4. Consider adding proxy verification script");
    }
}
