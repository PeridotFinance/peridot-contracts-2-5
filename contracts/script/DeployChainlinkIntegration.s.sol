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
import {PeridotVRFLiquidator} from "../contracts/contracts/ccip/PeridotVRFLiquidator.sol";

/**
 * @title DeployChainlinkIntegration
 * @dev Comprehensive deployment script for all Chainlink integration contracts
 *
 * Usage:
 * Phase 1 (Basic CCIP): forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployPhase1()" --rpc-url $RPC_URL --broadcast
 * Phase 2 (Read-only): forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployPhase2(address)" <PERIDOTTROLLER_ADDRESS> --rpc-url $RPC_URL --broadcast
 * Phase 3 (State-changing): forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployPhase3(address)" <PERIDOTTROLLER_ADDRESS> --rpc-url $RPC_URL --broadcast
 * Phase 4 (Price Oracle): forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployPhase4()" --rpc-url $RPC_URL --broadcast
 * Phase 5 (VRF): forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployPhase5(address,uint64,bytes32)" <PERIDOTTROLLER_ADDRESS> <VRF_SUBSCRIPTION_ID> <VRF_KEY_HASH> --rpc-url $RPC_URL --broadcast
 * All phases: forge script script/DeployChainlinkIntegration.s.sol:DeployChainlinkIntegration --sig "deployAll(address,uint64,bytes32)" <PERIDOTTROLLER_ADDRESS> <VRF_SUBSCRIPTION_ID> <VRF_KEY_HASH> --rpc-url $RPC_URL --broadcast
 */
contract DeployChainlinkIntegration is Script {
    // Network-specific addresses (you'll need to update these for your target networks)
    struct NetworkConfig {
        address ccipRouter;
        address linkToken;
        address vrfCoordinator;
        uint64 chainSelector;
    }

    // Ethereum Sepolia
    NetworkConfig public sepoliaConfig =
        NetworkConfig({
            ccipRouter: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
            linkToken: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            vrfCoordinator: 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625,
            chainSelector: 16015286601757825753
        });

    // Avalanche Fuji
    NetworkConfig public fujiConfig =
        NetworkConfig({
            ccipRouter: 0xF694E193200268f9a4868e4Aa017A0118C9a8177,
            linkToken: 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846,
            vrfCoordinator: 0x2eD832Ba664535e5886b75D64C46EB9a228C2610,
            chainSelector: 14767482510784806043
        });

    // Deployment tracking
    struct DeployedContracts {
        address ccipSender;
        address ccipReceiver;
        address peridotCCIPReader;
        address peridotCCIPSender;
        address peridotCCIPAdapter;
        address peridotCCIPController;
        address chainlinkPriceOracle;
        address peridotVRFLiquidator;
    }

    DeployedContracts public deployedContracts;

    function getCurrentNetworkConfig()
        public
        view
        returns (NetworkConfig memory)
    {
        uint256 chainId = block.chainid;
        if (chainId == 11155111) {
            // Sepolia
            return sepoliaConfig;
        } else if (chainId == 43113) {
            // Fuji
            return fujiConfig;
        } else {
            revert("Unsupported network");
        }
    }

    /**
     * @dev Deploy Phase 1: Basic CCIP contracts
     */
    function deployPhase1() public {
        NetworkConfig memory config = getCurrentNetworkConfig();

        vm.startBroadcast();

        console.log("=== Deploying Phase 1: Basic CCIP Contracts ===");
        console.log("Network Chain ID:", block.chainid);
        console.log("CCIP Router:", config.ccipRouter);
        console.log("LINK Token:", config.linkToken);

        // Deploy CCIPSender
        CCIPSender ccipSender = new CCIPSender(
            config.ccipRouter,
            config.linkToken
        );
        deployedContracts.ccipSender = address(ccipSender);
        console.log("CCIPSender deployed at:", address(ccipSender));

        // Deploy CCIPReceiver
        CCIPReceiver_Unsafe ccipReceiver = new CCIPReceiver_Unsafe(
            config.ccipRouter
        );
        deployedContracts.ccipReceiver = address(ccipReceiver);
        console.log("CCIPReceiver deployed at:", address(ccipReceiver));

        vm.stopBroadcast();

        console.log("=== Phase 1 Deployment Complete ===");
        _logDeployedAddresses();
    }

    /**
     * @dev Deploy Phase 2: Read-only Peridot integration
     */
    function deployPhase2(address peridottrollerAddress) public {
        require(
            peridottrollerAddress != address(0),
            "Invalid Peridottroller address"
        );
        NetworkConfig memory config = getCurrentNetworkConfig();

        vm.startBroadcast();

        console.log("=== Deploying Phase 2: Read-only Peridot Integration ===");
        console.log("Peridottroller:", peridottrollerAddress);

        // Deploy PeridotCCIPReader
        PeridotCCIPReader peridotCCIPReader = new PeridotCCIPReader(
            config.ccipRouter,
            peridottrollerAddress
        );
        deployedContracts.peridotCCIPReader = address(peridotCCIPReader);
        console.log(
            "PeridotCCIPReader deployed at:",
            address(peridotCCIPReader)
        );

        // Deploy PeridotCCIPSender
        PeridotCCIPSender peridotCCIPSender = new PeridotCCIPSender(
            config.ccipRouter
        );
        deployedContracts.peridotCCIPSender = address(peridotCCIPSender);
        console.log(
            "PeridotCCIPSender deployed at:",
            address(peridotCCIPSender)
        );

        vm.stopBroadcast();

        console.log("=== Phase 2 Deployment Complete ===");
        _logDeployedAddresses();
    }

    /**
     * @dev Deploy Phase 3: State-changing Peridot integration
     */
    function deployPhase3(address peridottrollerAddress) public {
        require(
            peridottrollerAddress != address(0),
            "Invalid Peridottroller address"
        );
        NetworkConfig memory config = getCurrentNetworkConfig();

        vm.startBroadcast();

        console.log(
            "=== Deploying Phase 3: State-changing Peridot Integration ==="
        );
        console.log("Peridottroller:", peridottrollerAddress);

        // Deploy PeridotCCIPAdapter
        PeridotCCIPAdapter peridotCCIPAdapter = new PeridotCCIPAdapter(
            config.ccipRouter,
            peridottrollerAddress
        );
        deployedContracts.peridotCCIPAdapter = address(peridotCCIPAdapter);
        console.log(
            "PeridotCCIPAdapter deployed at:",
            address(peridotCCIPAdapter)
        );

        // Deploy PeridotCCIPController
        PeridotCCIPController peridotCCIPController = new PeridotCCIPController(
            config.ccipRouter
        );
        deployedContracts.peridotCCIPController = address(
            peridotCCIPController
        );
        console.log(
            "PeridotCCIPController deployed at:",
            address(peridotCCIPController)
        );

        vm.stopBroadcast();

        console.log("=== Phase 3 Deployment Complete ===");
        _logDeployedAddresses();
    }

    /**
     * @dev Deploy Phase 4: Chainlink Price Oracle
     */
    function deployPhase4() public {
        vm.startBroadcast();

        console.log("=== Deploying Phase 4: Chainlink Price Oracle ===");

        // Deploy ChainlinkPriceOracle with deployer as admin
        ChainlinkPriceOracle chainlinkPriceOracle = new ChainlinkPriceOracle(
            msg.sender
        );
        deployedContracts.chainlinkPriceOracle = address(chainlinkPriceOracle);
        console.log(
            "ChainlinkPriceOracle deployed at:",
            address(chainlinkPriceOracle)
        );
        console.log("Oracle admin set to:", msg.sender);

        vm.stopBroadcast();

        console.log("=== Phase 4 Deployment Complete ===");
        _logDeployedAddresses();
    }

    /**
     * @dev Deploy Phase 5: VRF Liquidator
     */
    function deployPhase5(
        address peridottrollerAddress,
        uint64 vrfSubscriptionId,
        bytes32 vrfKeyHash
    ) public {
        require(
            peridottrollerAddress != address(0),
            "Invalid Peridottroller address"
        );
        require(vrfSubscriptionId != 0, "Invalid VRF subscription ID");
        require(vrfKeyHash != bytes32(0), "Invalid VRF key hash");

        NetworkConfig memory config = getCurrentNetworkConfig();

        vm.startBroadcast();

        console.log("=== Deploying Phase 5: VRF Liquidator ===");
        console.log("VRF Coordinator:", config.vrfCoordinator);
        console.log("VRF Subscription ID:", vrfSubscriptionId);
        console.log("VRF Key Hash:", vm.toString(vrfKeyHash));

        // Deploy PeridotVRFLiquidator
        PeridotVRFLiquidator peridotVRFLiquidator = new PeridotVRFLiquidator(
            config.vrfCoordinator,
            vrfSubscriptionId,
            vrfKeyHash,
            peridottrollerAddress
        );
        deployedContracts.peridotVRFLiquidator = address(peridotVRFLiquidator);
        console.log(
            "PeridotVRFLiquidator deployed at:",
            address(peridotVRFLiquidator)
        );

        vm.stopBroadcast();

        console.log("=== Phase 5 Deployment Complete ===");
        _logDeployedAddresses();
    }

    /**
     * @dev Deploy all phases in sequence
     */
    function deployAll(
        address peridottrollerAddress,
        uint64 vrfSubscriptionId,
        bytes32 vrfKeyHash
    ) public {
        console.log(
            "=== Starting Complete Chainlink Integration Deployment ==="
        );

        deployPhase1();
        deployPhase2(peridottrollerAddress);
        deployPhase3(peridottrollerAddress);
        deployPhase4();
        deployPhase5(peridottrollerAddress, vrfSubscriptionId, vrfKeyHash);

        console.log("=== ALL PHASES DEPLOYED SUCCESSFULLY ===");
        _logFinalSummary();
    }

    /**
     * @dev Configure basic CCIP allowlists for testing
     */
    function configureBasicCCIP(
        address senderContract,
        address receiverContract,
        uint64 destinationChainSelector,
        uint64 sourceChainSelector
    ) public {
        vm.startBroadcast();

        console.log("=== Configuring Basic CCIP Allowlists ===");

        // Configure sender
        CCIPSender sender = CCIPSender(senderContract);
        sender.allowlistDestinationChain(destinationChainSelector, true);
        console.log(
            "Allowlisted destination chain on sender:",
            destinationChainSelector
        );

        // Configure receiver
        CCIPReceiver_Unsafe receiver = CCIPReceiver_Unsafe(receiverContract);
        receiver.allowlistSourceChain(sourceChainSelector, true);
        receiver.allowlistSender(senderContract, true);
        console.log(
            "Allowlisted source chain on receiver:",
            sourceChainSelector
        );
        console.log("Allowlisted sender on receiver:", senderContract);

        vm.stopBroadcast();

        console.log("=== Basic CCIP Configuration Complete ===");
    }

    /**
     * @dev Configure Peridot CCIP integration
     */
    function configurePeridotCCIP(
        address readerContract,
        address senderContract,
        address adapterContract,
        address controllerContract,
        uint64 destinationChainSelector,
        uint64 sourceChainSelector
    ) public {
        vm.startBroadcast();

        console.log("=== Configuring Peridot CCIP Integration ===");

        // Configure reader
        PeridotCCIPReader reader = PeridotCCIPReader(readerContract);
        reader.allowlistSourceChain(sourceChainSelector, true);
        reader.allowlistSender(sourceChainSelector, senderContract, true);

        // Configure sender
        PeridotCCIPSender sender = PeridotCCIPSender(senderContract);
        sender.allowlistDestinationChain(destinationChainSelector, true);
        sender.setReceiver(destinationChainSelector, readerContract);

        // Configure adapter
        PeridotCCIPAdapter adapter = PeridotCCIPAdapter(adapterContract);
        adapter.allowlistSourceChain(sourceChainSelector, true);
        adapter.allowlistSender(sourceChainSelector, controllerContract, true);

        // Configure controller
        PeridotCCIPController controller = PeridotCCIPController(
            controllerContract
        );
        controller.allowlistDestinationChain(destinationChainSelector, true);
        controller.setReceiver(destinationChainSelector, adapterContract);

        vm.stopBroadcast();

        console.log("=== Peridot CCIP Configuration Complete ===");
    }

    function _logDeployedAddresses() internal view {
        console.log("\n--- Deployed Contract Addresses ---");
        if (deployedContracts.ccipSender != address(0)) {
            console.log("CCIPSender:", deployedContracts.ccipSender);
        }
        if (deployedContracts.ccipReceiver != address(0)) {
            console.log("CCIPReceiver:", deployedContracts.ccipReceiver);
        }
        if (deployedContracts.peridotCCIPReader != address(0)) {
            console.log(
                "PeridotCCIPReader:",
                deployedContracts.peridotCCIPReader
            );
        }
        if (deployedContracts.peridotCCIPSender != address(0)) {
            console.log(
                "PeridotCCIPSender:",
                deployedContracts.peridotCCIPSender
            );
        }
        if (deployedContracts.peridotCCIPAdapter != address(0)) {
            console.log(
                "PeridotCCIPAdapter:",
                deployedContracts.peridotCCIPAdapter
            );
        }
        if (deployedContracts.peridotCCIPController != address(0)) {
            console.log(
                "PeridotCCIPController:",
                deployedContracts.peridotCCIPController
            );
        }
        if (deployedContracts.chainlinkPriceOracle != address(0)) {
            console.log(
                "ChainlinkPriceOracle:",
                deployedContracts.chainlinkPriceOracle
            );
        }
        if (deployedContracts.peridotVRFLiquidator != address(0)) {
            console.log(
                "PeridotVRFLiquidator:",
                deployedContracts.peridotVRFLiquidator
            );
        }
        console.log("-----------------------------------\n");
    }

    function _logFinalSummary() internal view {
        console.log("\n🎉 CHAINLINK INTEGRATION DEPLOYMENT SUMMARY 🎉");
        console.log("================================================");
        console.log("Network Chain ID:", block.chainid);
        console.log("Deployer Address:", msg.sender);
        console.log("");
        console.log("✅ Phase 1 - Basic CCIP:");
        console.log("   CCIPSender:", deployedContracts.ccipSender);
        console.log("   CCIPReceiver:", deployedContracts.ccipReceiver);
        console.log("");
        console.log("✅ Phase 2 - Read-only Integration:");
        console.log(
            "   PeridotCCIPReader:",
            deployedContracts.peridotCCIPReader
        );
        console.log(
            "   PeridotCCIPSender:",
            deployedContracts.peridotCCIPSender
        );
        console.log("");
        console.log("✅ Phase 3 - State-changing Integration:");
        console.log(
            "   PeridotCCIPAdapter:",
            deployedContracts.peridotCCIPAdapter
        );
        console.log(
            "   PeridotCCIPController:",
            deployedContracts.peridotCCIPController
        );
        console.log("");
        console.log("✅ Phase 4 - Price Oracle:");
        console.log(
            "   ChainlinkPriceOracle:",
            deployedContracts.chainlinkPriceOracle
        );
        console.log("");
        console.log("✅ Phase 5 - VRF Liquidator:");
        console.log(
            "   PeridotVRFLiquidator:",
            deployedContracts.peridotVRFLiquidator
        );
        console.log("");
        console.log("🚀 All Chainlink integrations deployed successfully!");
        console.log("================================================");
    }
}
