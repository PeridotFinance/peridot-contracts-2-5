// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/SimplePriceOracle.sol";

contract DeploySimplePriceOracle is Script {
    // Network-specific Chainlink aggregator addresses
    struct ChainlinkFeeds {
        address ethUsd;
        address btcUsd;
        address usdcUsd;
        address usdtUsd;
        address linkUsd;
    }

    // Asset addresses for different networks
    struct AssetAddresses {
        address weth;
        address wbtc;
        address usdc;
        address usdt;
        address link;
    }

    SimplePriceOracle public oracle;

    // Default configuration
    uint256 public constant DEFAULT_STALE_THRESHOLD = 3600; // 1 hour

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying SimplePriceOracle...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the SimplePriceOracle
        oracle = new SimplePriceOracle(DEFAULT_STALE_THRESHOLD);

        console.log("SimplePriceOracle deployed to:", address(oracle));

        // Configure the oracle based on the current network
        _configureForNetwork(deployer);

        vm.stopBroadcast();

        // Log deployment information
        _logDeploymentInfo();
    }

    function _configureForNetwork(address deployer) internal {
        uint256 chainId = block.chainid;

        console.log("Configuring for network:", chainId);

        if (chainId == 10143) {
            _configureMainnet(deployer);
        } else if (chainId == 5) {
            _configureGoerli(deployer);
        } else {
            console.log("Unknown network, configuring with basic setup");
            _configureBasic(deployer);
        }
    }

    function _configureMainnet(address deployer) internal {
        console.log("Configuring for Ethereum Mainnet");

        ChainlinkFeeds memory feeds = ChainlinkFeeds({
            ethUsd: 0x0c76859E85727683Eeba0C70Bc2e0F5781337818,
            btcUsd: 0x2Cd9D7E85494F68F5aF08EF96d6FD5e8F71B4d31,
            usdcUsd: 0x70BB0758a38ae43418ffcEd9A25273dd4e804D15,
            usdtUsd: 0x14eE6bE30A91989851Dc23203E41C804D4D71441,
            linkUsd: 0x4682035965Cd2B88759193ee2660d8A0766e1391
        });

        AssetAddresses memory assets = AssetAddresses({
            weth: 0xB5a30b0FDc5EA94A52fDc42e3E9760Cb8449Fb37,
            wbtc: 0xcf5a6076cfa32686c0Df13aBaDa2b40dec133F1d,
            usdc: 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea,
            usdt: 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D,
            link: 0x514910771AF9Ca656af840dff83E8264EcF986CA
        });

        _registerChainlinkFeeds(feeds, assets);
    }

    function _configureGoerli(address deployer) internal {
        console.log("Configuring for Goerli Testnet");

        ChainlinkFeeds memory feeds = ChainlinkFeeds({
            ethUsd: 0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e,
            btcUsd: 0xA39434A63A52E749F02807ae27335515BA4b07F7,
            usdcUsd: 0xAb5c49580294Aff77670F839ea425f5b78ab3Ae7,
            usdtUsd: 0x4682035965Cd2B88759193ee2660d8A0766e1391, // Not available on Goerli
            linkUsd: 0x48731cF7e84dc94C5f84577882c14Be11a5B7456
        });

        AssetAddresses memory assets = AssetAddresses({
            weth: 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6,
            wbtc: 0x4682035965Cd2B88759193ee2660d8A0766e1391, // Use mock address or skip
            usdc: 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea,
            usdt: 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D,
            link: 0x326C977E6efc84E512bB9C30f76E30c160eD06FB
        });

        _registerChainlinkFeeds(feeds, assets);
    }

    function _configureBasic(address deployer) internal {
        console.log("Configuring basic setup for unknown network");

        // Set deployer as admin
        // oracle.setAdmin(deployer); // Already set as deployer is owner

        console.log("Basic configuration completed");
        console.log(
            "You'll need to manually register Chainlink feeds for this network"
        );
    }

    function _registerChainlinkFeeds(
        ChainlinkFeeds memory feeds,
        AssetAddresses memory assets
    ) internal {
        console.log("Registering Chainlink price feeds...");

        // Register ETH/USD feed
        if (feeds.ethUsd != address(0) && assets.weth != address(0)) {
            oracle.registerChainlinkFeed(assets.weth, feeds.ethUsd);
            console.log("Registered ETH/USD feed for WETH");
        }

        // Register BTC/USD feed
        if (feeds.btcUsd != address(0) && assets.wbtc != address(0)) {
            oracle.registerChainlinkFeed(assets.wbtc, feeds.btcUsd);
            console.log("Registered BTC/USD feed for WBTC");
        }

        // Register USDC/USD feed
        if (feeds.usdcUsd != address(0) && assets.usdc != address(0)) {
            oracle.registerChainlinkFeed(assets.usdc, feeds.usdcUsd);
            console.log("Registered USDC/USD feed");
        }

        // Register USDT/USD feed
        if (feeds.usdtUsd != address(0) && assets.usdt != address(0)) {
            oracle.registerChainlinkFeed(assets.usdt, feeds.usdtUsd);
            console.log("Registered USDT/USD feed");
        }

        // Register LINK/USD feed
        if (feeds.linkUsd != address(0) && assets.link != address(0)) {
            oracle.registerChainlinkFeed(assets.link, feeds.linkUsd);
            console.log("Registered LINK/USD feed");
        }

        console.log("Chainlink feed registration completed");
    }

    function _logDeploymentInfo() internal view {
        console.log("=== SimplePriceOracle Deployment Complete ===");
        console.log("Contract Address:", address(oracle));
        console.log(
            "Stale Threshold:",
            oracle.chainlinkPriceStaleThreshold(),
            "seconds"
        );
        console.log("Chain ID:", block.chainid);
        console.log("Block Number:", block.number);
        console.log("=== Deployment Info End ===");
    }

    // Helper function to deploy and configure with custom settings
    function deployWithCustomSettings(
        uint256 staleThreshold,
        address[] memory assets,
        address[] memory aggregators
    ) external {
        require(
            assets.length == aggregators.length,
            "Assets and aggregators length mismatch"
        );

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy with custom stale threshold
        oracle = new SimplePriceOracle(staleThreshold);

        // Register custom feeds
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0) && aggregators[i] != address(0)) {
                oracle.registerChainlinkFeed(assets[i], aggregators[i]);
            }
        }

        vm.stopBroadcast();

        console.log("Custom SimplePriceOracle deployed to:", address(oracle));
    }
}
