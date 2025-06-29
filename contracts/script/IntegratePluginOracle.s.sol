// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/PluginDirectOracle.sol";
import "../contracts/Peridottroller.sol";

contract IntegratePluginOracle is Script {
    // Plugin aggregator addresses from their documentation
    // These are examples - get real addresses from https://feeds.goplugin.co
    address constant XDC_USD_AGGREGATOR =
        address(0x7D276a421fa99B0E86aC3B5c47205987De76B497); // Example XDC/USD

    // Asset addresses (replace with your actual token addresses)
    address constant XDC_TOKEN = 0x0000000000000000000000000000000000000001; // Replace with actual XDC token

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Plugin Oracle Integration ===");
        console.log("Deployer:", deployer);

        // Step 1: Deploy Plugin Oracle
        console.log("\n1. Deploying PluginDirectOracle...");
        PluginDirectOracle oracle = new PluginDirectOracle(3600); // 1 hour stale threshold
        console.log("Oracle deployed at:", address(oracle));

        // Step 2: Deploy and register feeds for each asset
        console.log("\n2. Setting up price feeds...");

        // XDC/USD Feed
        console.log("Setting up XDC/USD feed...");
        address xdcFeedsAccess = oracle.deployAndRegisterFeed(
            XDC_TOKEN,
            XDC_USD_AGGREGATOR
        );
        console.log("XDC FeedsAccess deployed at:", xdcFeedsAccess);

        // Step 3: Set custom stale thresholds if needed
        console.log("\n3. Setting custom stale thresholds...");
        oracle.setAssetStaleThreshold(XDC_TOKEN, 1800); // 30 minutes for XDC

        console.log("\n=== Integration Complete ===");
        console.log("Oracle Address:", address(oracle));
        console.log("Owner:", oracle.getOwner());
        console.log("Default Stale Threshold:", oracle.defaultStaleThreshold());

        console.log("\n=== Next Steps ===");
        console.log("1. Update Peridottroller to use this oracle:");
        console.log("   peridottroller._setPriceOracle(", address(oracle), ")");
        console.log("2. Verify feeds are working by calling:");
        console.log("   oracle.getUnderlyingPrice(pTokenAddress)");

        vm.stopBroadcast();
    }

    // Helper function to verify oracle integration
    function verifyIntegration(
        address oracleAddress,
        address peridottrollerAddress
    ) external view {
        PluginDirectOracle oracle = PluginDirectOracle(oracleAddress);
        Peridottroller peridottroller = Peridottroller(peridottrollerAddress);

        console.log("=== Verification ===");
        console.log("Oracle address:", oracleAddress);
        console.log("Peridottroller oracle:", address(peridottroller.oracle()));
        console.log(
            "Integration status:",
            address(peridottroller.oracle()) == oracleAddress
                ? "Integrated"
                : "Not integrated"
        );
    }
}
