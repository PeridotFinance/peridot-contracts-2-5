// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CCIPSender} from "../contracts/contracts/ccip/CCIPSender.sol";
import {CCIPReceiver_Unsafe} from "../contracts/contracts/ccip/CCIPReceiver.sol";
import {PeridotCCIPReader} from "../contracts/contracts/ccip/PeridotCCIPReader.sol";
import {PeridotCCIPSender} from "../contracts/contracts/ccip/PeridotCCIPSender.sol";
import {PeridotCCIPAdapter} from "../contracts/contracts/ccip/PeridotCCIPAdapter.sol";
import {PeridotCCIPController} from "../contracts/contracts/ccip/PeridotCCIPController.sol";
import {ChainlinkPriceOracle} from "../contracts/contracts/ccip/ChainlinkPriceOracle.sol";

/**
 * @title ConfigureChainlinkCCIP
 * @dev Configuration script for setting up CCIP allowlists and cross-chain communication
 *
 * Usage Examples:
 *
 * 1. Configure basic CCIP (Phase 1):
 * forge script script/ConfigureChainlinkCCIP.s.sol:ConfigureChainlinkCCIP \
 *   --sig "configureBasicCCIP(address,address)" \
 *   <SENDER_ADDRESS> <RECEIVER_ADDRESS> \
 *   --rpc-url $RPC_URL --broadcast
 *
 * 2. Configure Peridot integration (Phase 2 & 3):
 * forge script script/ConfigureChainlinkCCIP.s.sol:ConfigureChainlinkCCIP \
 *   --sig "configurePeridotIntegration(address,address,address,address)" \
 *   <READER_ADDRESS> <SENDER_ADDRESS> <ADAPTER_ADDRESS> <CONTROLLER_ADDRESS> \
 *   --rpc-url $RPC_URL --broadcast
 *
 * 3. Configure price feeds (Phase 4):
 * forge script script/ConfigureChainlinkCCIP.s.sol:ConfigureChainlinkCCIP \
 *   --sig "configurePriceFeeds(address)" \
 *   <ORACLE_ADDRESS> \
 *   --rpc-url $RPC_URL --broadcast
 */
contract ConfigureChainlinkCCIP is Script {
    // Chain selectors for CCIP
    uint64 constant ETHEREUM_SEPOLIA_SELECTOR = 16015286601757825753;
    uint64 constant AVALANCHE_FUJI_SELECTOR = 14767482510784806043;
    uint64 constant POLYGON_MUMBAI_SELECTOR = 12532609583862916517;
    uint64 constant ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;
    uint64 constant OPTIMISM_SEPOLIA_SELECTOR = 5224473277236331295;

    // Common price feed addresses (Sepolia testnet)
    address constant ETH_USD_FEED_SEPOLIA =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant BTC_USD_FEED_SEPOLIA =
        0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant USDC_USD_FEED_SEPOLIA =
        0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant LINK_USD_FEED_SEPOLIA =
        0xc59E3633BAAC79493d908e63626716e204A45EdF;

    function getCurrentChainSelector() public view returns (uint64) {
        uint256 chainId = block.chainid;
        if (chainId == 11155111) return ETHEREUM_SEPOLIA_SELECTOR; // Sepolia
        if (chainId == 43113) return AVALANCHE_FUJI_SELECTOR; // Fuji
        if (chainId == 80001) return POLYGON_MUMBAI_SELECTOR; // Mumbai
        if (chainId == 421614) return ARBITRUM_SEPOLIA_SELECTOR; // Arbitrum Sepolia
        if (chainId == 11155420) return OPTIMISM_SEPOLIA_SELECTOR; // Optimism Sepolia
        revert("Unsupported chain for CCIP");
    }

    function getDestinationChainSelector() public view returns (uint64) {
        uint256 chainId = block.chainid;
        // Return the "other" chain selector for cross-chain setup
        if (chainId == 11155111) return AVALANCHE_FUJI_SELECTOR; // If on Sepolia, target Fuji
        if (chainId == 43113) return ETHEREUM_SEPOLIA_SELECTOR; // If on Fuji, target Sepolia
        revert("Please manually specify destination chain");
    }

    /**
     * @dev Configure basic CCIP contracts (Phase 1)
     */
    function configureBasicCCIP(
        address senderAddress,
        address receiverAddress
    ) public {
        require(senderAddress != address(0), "Invalid sender address");
        require(receiverAddress != address(0), "Invalid receiver address");

        uint64 sourceChain = getCurrentChainSelector();
        uint64 destinationChain = getDestinationChainSelector();

        vm.startBroadcast();

        console.log("=== Configuring Basic CCIP Contracts ===");
        console.log("Current Chain Selector:", sourceChain);
        console.log("Destination Chain Selector:", destinationChain);
        console.log("Sender Address:", senderAddress);
        console.log("Receiver Address:", receiverAddress);

        // Configure sender to send to destination chain
        CCIPSender sender = CCIPSender(senderAddress);
        sender.allowlistDestinationChain(destinationChain, true);
        console.log("✅ Allowlisted destination chain on sender");

        // Configure receiver to receive from source chain and sender
        CCIPReceiver_Unsafe receiver = CCIPReceiver_Unsafe(receiverAddress);
        receiver.allowlistSourceChain(sourceChain, true);
        receiver.allowlistSender(senderAddress, true);
        console.log("✅ Allowlisted source chain and sender on receiver");

        vm.stopBroadcast();

        console.log("=== Basic CCIP Configuration Complete ===");
    }

    /**
     * @dev Configure Peridot CCIP integration (Phase 2 & 3)
     */
    function configurePeridotIntegration(
        address readerAddress,
        address senderAddress,
        address adapterAddress,
        address controllerAddress
    ) public {
        require(readerAddress != address(0), "Invalid reader address");
        require(senderAddress != address(0), "Invalid sender address");
        require(adapterAddress != address(0), "Invalid adapter address");
        require(controllerAddress != address(0), "Invalid controller address");

        uint64 sourceChain = getCurrentChainSelector();
        uint64 destinationChain = getDestinationChainSelector();

        vm.startBroadcast();

        console.log("=== Configuring Peridot CCIP Integration ===");
        console.log("Reader Address:", readerAddress);
        console.log("Sender Address:", senderAddress);
        console.log("Adapter Address:", adapterAddress);
        console.log("Controller Address:", controllerAddress);

        // Configure PeridotCCIPReader
        PeridotCCIPReader reader = PeridotCCIPReader(readerAddress);
        reader.allowlistSourceChain(sourceChain, true);
        reader.allowlistSender(sourceChain, senderAddress, true);
        console.log("✅ Configured PeridotCCIPReader allowlists");

        // Configure PeridotCCIPSender
        PeridotCCIPSender sender = PeridotCCIPSender(senderAddress);
        sender.allowlistDestinationChain(destinationChain, true);
        sender.setReceiver(destinationChain, readerAddress);
        console.log("✅ Configured PeridotCCIPSender destination and receiver");

        // Configure PeridotCCIPAdapter
        PeridotCCIPAdapter adapter = PeridotCCIPAdapter(adapterAddress);
        adapter.allowlistSourceChain(sourceChain, true);
        adapter.allowlistSender(sourceChain, controllerAddress, true);
        console.log("✅ Configured PeridotCCIPAdapter allowlists");

        // Configure PeridotCCIPController
        PeridotCCIPController controller = PeridotCCIPController(
            controllerAddress
        );
        controller.allowlistDestinationChain(destinationChain, true);
        controller.setReceiver(destinationChain, adapterAddress);
        console.log(
            "✅ Configured PeridotCCIPController destination and receiver"
        );

        vm.stopBroadcast();

        console.log("=== Peridot CCIP Integration Configuration Complete ===");
    }

    /**
     * @dev Configure price feeds for ChainlinkPriceOracle (Phase 4)
     */
    function configurePriceFeeds(address oracleAddress) public {
        require(oracleAddress != address(0), "Invalid oracle address");

        vm.startBroadcast();

        console.log("=== Configuring Chainlink Price Feeds ===");
        console.log("Oracle Address:", oracleAddress);

        ChainlinkPriceOracle oracle = ChainlinkPriceOracle(oracleAddress);

        // Note: You'll need to replace these with actual pToken addresses
        // This is just an example setup for Sepolia testnet
        if (block.chainid == 11155111) {
            // Sepolia
            console.log("Setting up price feeds for Sepolia testnet...");

            // Example: Set ETH/USD feed (you'll need actual pToken addresses)
            // oracle.setPriceFeed(pETH_ADDRESS, ETH_USD_FEED_SEPOLIA);
            // oracle.setPriceFeed(pBTC_ADDRESS, BTC_USD_FEED_SEPOLIA);
            // oracle.setPriceFeed(pUSDC_ADDRESS, USDC_USD_FEED_SEPOLIA);
            // oracle.setPriceFeed(pLINK_ADDRESS, LINK_USD_FEED_SEPOLIA);

            console.log(
                "📝 Note: Update this script with actual pToken addresses"
            );
            console.log("Available price feeds:");
            console.log("  ETH/USD:", ETH_USD_FEED_SEPOLIA);
            console.log("  BTC/USD:", BTC_USD_FEED_SEPOLIA);
            console.log("  USDC/USD:", USDC_USD_FEED_SEPOLIA);
            console.log("  LINK/USD:", LINK_USD_FEED_SEPOLIA);
        }

        vm.stopBroadcast();

        console.log("=== Price Feeds Configuration Complete ===");
    }

    /**
     * @dev Set up cross-chain configuration between two specific chains
     */
    function setupCrossChainConfig(
        address localSender,
        address remoteSender,
        address localReceiver,
        address remoteReceiver,
        uint64 remoteChainSelector
    ) public {
        vm.startBroadcast();

        console.log("=== Setting Up Cross-Chain Configuration ===");
        console.log("Remote Chain Selector:", remoteChainSelector);
        console.log("Local Sender:", localSender);
        console.log("Remote Receiver:", remoteReceiver);

        // Configure local sender to send to remote receiver
        if (localSender != address(0)) {
            CCIPSender sender = CCIPSender(localSender);
            sender.allowlistDestinationChain(remoteChainSelector, true);
            console.log("✅ Allowlisted destination chain on local sender");
        }

        // Configure local receiver to receive from remote sender
        if (localReceiver != address(0) && remoteSender != address(0)) {
            CCIPReceiver_Unsafe receiver = CCIPReceiver_Unsafe(localReceiver);
            receiver.allowlistSourceChain(remoteChainSelector, true);
            receiver.allowlistSender(remoteSender, true);
            console.log(
                "✅ Allowlisted source chain and remote sender on local receiver"
            );
        }

        vm.stopBroadcast();

        console.log("=== Cross-Chain Configuration Complete ===");
    }

    /**
     * @dev Emergency function to remove allowlists
     */
    function removeAllowlists(
        address contractAddress,
        uint64 chainSelector,
        address senderAddress
    ) public {
        vm.startBroadcast();

        console.log("=== Removing Allowlists (Emergency) ===");
        console.log("Contract:", contractAddress);
        console.log("Chain Selector:", chainSelector);
        console.log("Sender:", senderAddress);

        try
            CCIPSender(contractAddress).allowlistDestinationChain(
                chainSelector,
                false
            )
        {
            console.log("✅ Removed destination chain allowlist");
        } catch {
            console.log("⚠️  Contract is not a CCIPSender or call failed");
        }

        try
            CCIPReceiver_Unsafe(contractAddress).allowlistSourceChain(
                chainSelector,
                false
            )
        {
            console.log("✅ Removed source chain allowlist");
        } catch {
            console.log("⚠️  Contract is not a CCIPReceiver or call failed");
        }

        try
            CCIPReceiver_Unsafe(contractAddress).allowlistSender(
                senderAddress,
                false
            )
        {
            console.log("✅ Removed sender allowlist");
        } catch {
            console.log("⚠️  Contract is not a CCIPReceiver or call failed");
        }

        vm.stopBroadcast();

        console.log("=== Allowlist Removal Complete ===");
    }

    /**
     * @dev Helper function to display current network info
     */
    function displayNetworkInfo() public view {
        console.log("=== Network Information ===");
        console.log("Chain ID:", block.chainid);
        console.log("Chain Selector:", getCurrentChainSelector());
        console.log("Suggested Destination:", getDestinationChainSelector());
        console.log("========================");
    }
}
