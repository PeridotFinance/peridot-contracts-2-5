// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/SimplePriceOracle.sol";

contract ConfigureSimplePriceOracle is Script {
    SimplePriceOracle public oracle;

    function run() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        oracle = SimplePriceOracle(oracleAddress);

        console.log("Configuring SimplePriceOracle at:", oracleAddress);
        console.log(
            "Current stale threshold:",
            oracle.chainlinkPriceStaleThreshold()
        );

        vm.startBroadcast(deployerPrivateKey);

        // Example configurations - customize as needed
        _updateStaleThreshold();
        _addNewAdmin();
        _registerAdditionalFeeds();
        _setManualPrices();

        vm.stopBroadcast();

        console.log("Configuration completed");
    }

    function _updateStaleThreshold() internal {
        // Update stale threshold to 2 hours (7200 seconds)
        uint256 newThreshold = 7200;

        try oracle.setChainlinkStaleThreshold(newThreshold) {
            console.log("Updated stale threshold to:", newThreshold);
        } catch {
            console.log("Failed to update stale threshold - check permissions");
        }
    }

    function _addNewAdmin() internal {
        // Add a new admin address
        address newAdmin = vm.envOr("NEW_ADMIN", address(0));

        if (newAdmin != address(0)) {
            try oracle.setAdmin(newAdmin) {
                console.log("Added new admin:", newAdmin);
            } catch {
                console.log("Failed to add new admin - check permissions");
            }
        }
    }

    function _registerAdditionalFeeds() internal {
        // Register additional price feeds
        address[] memory assets = new address[](2);
        address[] memory aggregators = new address[](2);

        // Example: Register custom token feeds
        assets[0] = vm.envOr("CUSTOM_TOKEN_1", address(0));
        aggregators[0] = vm.envOr("CUSTOM_AGGREGATOR_1", address(0));

        assets[1] = vm.envOr("CUSTOM_TOKEN_2", address(0));
        aggregators[1] = vm.envOr("CUSTOM_AGGREGATOR_2", address(0));

        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0) && aggregators[i] != address(0)) {
                try oracle.registerChainlinkFeed(assets[i], aggregators[i]) {
                    console.log("Registered feed for asset:", assets[i]);
                    console.log("Aggregator:", aggregators[i]);
                } catch {
                    console.log(
                        "Failed to register feed for asset:",
                        assets[i]
                    );
                }
            }
        }
    }

    function _setManualPrices() internal {
        // Set manual prices for assets without Chainlink feeds
        address[] memory assets = new address[](2);
        uint256[] memory prices = new uint256[](2);

        // Example manual price settings
        assets[0] = vm.envOr("MANUAL_ASSET_1", address(0));
        prices[0] = vm.envOr("MANUAL_PRICE_1", uint256(0));

        assets[1] = vm.envOr("MANUAL_ASSET_2", address(0));
        prices[1] = vm.envOr("MANUAL_PRICE_2", uint256(0));

        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0) && prices[i] > 0) {
                try oracle.setDirectPrice(assets[i], prices[i]) {
                    console.log("Set manual price for asset:", assets[i]);
                    console.log("Price:", prices[i]);
                } catch {
                    console.log(
                        "Failed to set manual price for asset:",
                        assets[i]
                    );
                }
            }
        }
    }

    // Specific functions for common operations
    function registerSingleFeed() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address asset = vm.envAddress("ASSET_ADDRESS");
        address aggregator = vm.envAddress("AGGREGATOR_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        oracle = SimplePriceOracle(oracleAddress);

        vm.startBroadcast(deployerPrivateKey);
        oracle.registerChainlinkFeed(asset, aggregator);
        vm.stopBroadcast();

        console.log("Registered Chainlink feed:");
        console.log("Asset:", asset);
        console.log("Aggregator:", aggregator);
    }

    function setManualPrice() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address asset = vm.envAddress("ASSET_ADDRESS");
        uint256 price = vm.envUint("PRICE");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        oracle = SimplePriceOracle(oracleAddress);

        vm.startBroadcast(deployerPrivateKey);
        oracle.setDirectPrice(asset, price);
        vm.stopBroadcast();

        console.log("Set manual price:");
        console.log("Asset:", asset);
        console.log("Price:", price);
    }

    function updateCachedPrices() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        oracle = SimplePriceOracle(oracleAddress);

        // Get assets from environment or use default set
        address[] memory assets = _getAssetsToUpdate();

        vm.startBroadcast(deployerPrivateKey);
        oracle.updateChainlinkPrices(assets);
        vm.stopBroadcast();

        console.log("Updated cached prices for", assets.length, "assets");
    }

    function _getAssetsToUpdate() internal view returns (address[] memory) {
        // This would typically be configured based on your deployment
        address[] memory assets = new address[](5);

        // Example assets - customize based on your needs
        assets[0] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        assets[1] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
        assets[2] = 0xAb5c49580294Aff77670F839ea425f5b78ab3Ae7; // USDC
        assets[3] = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
        assets[4] = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI

        return assets;
    }
}
