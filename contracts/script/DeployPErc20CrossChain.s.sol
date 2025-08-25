// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PErc20CrossChain} from "../contracts/PErc20CrossChain.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {EIP20Interface} from "../contracts/EIP20Interface.sol";

/**
 * @title DeployPErc20CrossChain
 * @author Peridot
 * @notice Deploys a PErc20CrossChain contract for cross-chain lending operations.
 * @dev Usage: forge script script/DeployPErc20CrossChain.s.sol:DeployPErc20CrossChain --rpc-url <rpc_url> --private-key <private_key> --broadcast
 */
contract DeployPErc20CrossChain is Script {
    // --- CONFIGURATION CONSTANTS ---
    // !!! IMPORTANT: Replace these with your actual deployed contract addresses !!!

    // Core Infrastructure Addresses (Hub Chain)
    address constant PERIDOT_HUB_HANDLER_ADDRESS =
        0x91b2cb19Ce8072296732349ca26F78ad60c4FF40; // The single, central Hub Handler
    address constant UNDERLYING_TOKEN_ADDRESS =
        0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address constant PERIDOTTROLLER_ADDRESS =
        0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54;
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0xE83d1578AAD5E7DeA8cDcb73FD83dEcfD35C70b4;

    // PToken Configuration Parameters
    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e26;
    string constant PTOKEN_NAME = "Peridot Cross-Chain Axelar WBNB";
    string constant PTOKEN_SYMBOL = "pcaWBNB";
    uint8 constant PTOKEN_DECIMALS = 8;

    function run() public {
        console.log("=== PErc20CrossChain Deployment ===");
        console.log("Deploying with Hub Handler:", PERIDOT_HUB_HANDLER_ADDRESS);

        // Validate configuration
        require(
            PERIDOT_HUB_HANDLER_ADDRESS != address(0),
            "Hub Handler address not set"
        );
        require(
            UNDERLYING_TOKEN_ADDRESS != address(0),
            "Underlying token address not set"
        );
        require(
            PERIDOTTROLLER_ADDRESS != address(0),
            "Peridottroller address not set"
        );
        require(
            INTEREST_RATE_MODEL_ADDRESS != address(0),
            "Interest rate model address not set"
        );

        vm.startBroadcast();

        // 1. Deploy PErc20CrossChain, passing the Hub Handler address to the constructor
        console.log("1. Deploying PErc20CrossChain...");
        PErc20CrossChain pToken = new PErc20CrossChain(
            PERIDOT_HUB_HANDLER_ADDRESS
        );
        console.log("   PErc20CrossChain deployed at:", address(pToken));

        // 2. Initialize the PToken
        console.log("2. Initializing PToken...");
        pToken.initialize(
            UNDERLYING_TOKEN_ADDRESS,
            PeridottrollerInterface(PERIDOTTROLLER_ADDRESS),
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS),
            INITIAL_EXCHANGE_RATE_MANTISSA,
            PTOKEN_NAME,
            PTOKEN_SYMBOL,
            PTOKEN_DECIMALS
        );
        console.log("   PToken initialization: COMPLETED");

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log(PTOKEN_SYMBOL, "deployed at:", address(pToken));
        console.log("  -> Hub Handler:", pToken.hubHandler());

        console.log("\n=== Next Steps ===");
        console.log(
            "1. Add this market to Peridottroller: peridottroller._supportMarket(",
            address(pToken),
            ")"
        );
    }
}
