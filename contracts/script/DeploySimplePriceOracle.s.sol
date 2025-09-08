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
        address daiUsd;
    }

    // Asset addresses for different networks
    struct AssetAddresses {
        address weth;
        address wbtc;
        address usdc;
        address usdt;
        address link;
        address dai;
    }

    SimplePriceOracle public oracle;

    // Default configuration
    uint256 public constant DEFAULT_STALE_THRESHOLD = 3600; // 1 hour

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATEMAIN");
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

        if (chainId == 56) {
            _configureMainnet(deployer);
        } else if (chainId == 97) {
            _configureGoerli(deployer);
        } else {
            console.log("Unknown network, configuring with basic setup");
            _configureBasic(deployer);
        }
    }

    function _configureMainnet(address deployer) internal {
        console.log("Configuring for Monad Testnet");

        ChainlinkFeeds memory feeds = ChainlinkFeeds({
            ethUsd: 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e, // ETH/USD Chainlink feed
            btcUsd: 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf, // BTC/USD Chainlink feed
            usdcUsd: 0x51597f405303C4377E36123cBc172b13269EA163, // USDC/USD Chainlink feed
            usdtUsd: 0xB97Ad0E74fa7d920791E90258A6E2085088b4320, // USDT/USD Chainlink feed
            linkUsd: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE, // WBNB
            daiUsd: 0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA
        });

        AssetAddresses memory assets = AssetAddresses({
            weth: 0x2170Ed0880ac9A755fd29B2688956BD959F933F8, // WETH from addresses.MD
            wbtc: 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c, // WBTC from addresses.MD
            usdc: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d, // USDC from addresses.MD
            usdt: 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a, // USDT from addresses.MD
            link: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // Skip LINK - will be handled by your script
            dai: 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3
        });

        _registerChainlinkFeeds(feeds, assets);

        console.log("USD stablecoins set to $1.00");
        console.log(
            "Note: LINK prices will be updated by your automated script"
        );
        console.log(
            "Note: WMON prices should be set manually or via separate script"
        );
    }

    function _configureGoerli(address deployer) internal {
        console.log("Configuring for Goerli Testnet");

        ChainlinkFeeds memory feeds = ChainlinkFeeds({
            ethUsd: 0x143db3CEEfbdfe5631aDD3E50f7614B6ba708BA7, // ETH/USD Chainlink feed
            btcUsd: 0x5741306c21795FdCBb9b265Ea0255F499DFe515C, // BTC/USD Chainlink feed
            usdcUsd: 0x90c069C4538adAc136E051052E14c1cD799C41B7, // USDC/USD Chainlink feed
            usdtUsd: 0xEca2605f0BCF2BA5966372C99837b1F182d3D620, // USDT/USD Chainlink feed
            linkUsd: 0x1B329402Cb1825C6F30A0d92aB9E2862BE47333f, // Skip LINK - will be handled by your script
            daiUsd: 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3
        });

        AssetAddresses memory assets = AssetAddresses({
            weth: 0xB5a30b0FDc5EA94A52fDc42e3E9760Cb8449Fb37, // WETH from addresses.MD
            wbtc: 0x6ce8dA28E2f864420840cF74474eFf5fD80E65B8, // WBTC from addresses.MD
            usdc: 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea, // USDC from addresses.MD
            usdt: 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D, // AUSD from addresses.MD
            link: 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06, // Skip LINK - will be handled by your script
            dai: 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3
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

        if (feeds.daiUsd != address(0) && assets.dai != address(0)) {
            oracle.registerChainlinkFeed(assets.dai, feeds.daiUsd);
            console.log("Registered DAI/USD feed");
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
