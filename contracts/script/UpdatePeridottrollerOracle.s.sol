// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PluginDirectOracle.sol";
import "../contracts/PToken.sol";

contract UpdatePeridottrollerOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Replace these with your actual deployed addresses
        address peridottrollerAddress = vm.envAddress("PERIDOTTROLLER_ADDRESS");
        address newOracleAddress = vm.envAddress("PLUGIN_ORACLE_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Updating Peridottroller Oracle ===");
        console.log("Peridottroller:", peridottrollerAddress);
        console.log("New Oracle:", newOracleAddress);

        Peridottroller peridottroller = Peridottroller(peridottrollerAddress);
        PluginDirectOracle newOracle = PluginDirectOracle(newOracleAddress);

        // Get current oracle for comparison
        address currentOracle = address(peridottroller.oracle());
        console.log("Current Oracle:", currentOracle);

        // Update the oracle
        console.log("\nUpdating oracle...");
        uint result = peridottroller._setPriceOracle(
            PriceOracle(newOracleAddress)
        );

        if (result == 0) {
            console.log("Oracle updated successfully!");
            console.log("New Oracle:", address(peridottroller.oracle()));
        } else {
            console.log("Oracle update failed with error code:", result);
        }

        vm.stopBroadcast();
    }

    // Function to test oracle prices for all markets
    function testOraclePrices(address peridottrollerAddress) external view {
        Peridottroller peridottroller = Peridottroller(peridottrollerAddress);
        PToken[] memory markets = peridottroller.getAllMarkets();

        console.log("=== Testing Oracle Prices ===");
        console.log("Number of markets:", markets.length);

        for (uint i = 0; i < markets.length; i++) {
            PToken market = markets[i];
            console.log("\nMarket:", address(market));
            console.log("Symbol:", market.symbol());

            try peridottroller.oracle().getUnderlyingPrice(market) returns (
                uint price
            ) {
                console.log("Price:", price);
                console.log("Price (formatted):", price / 1e18, "USD");
            } catch Error(string memory reason) {
                console.log("Price fetch failed:", reason);
            } catch {
                console.log("Price fetch failed: Unknown error");
            }
        }
    }
}
