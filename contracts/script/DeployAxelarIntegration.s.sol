// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";
import {PeridotForwarder} from "../contracts/PeridotForwarder.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/console.sol";

/**
 * @title DeployAxelarIntegration
 * @author Peridot
 * @notice Comprehensive deployment script for Peridot's Axelar GMP integration
 * @dev Supports deployment of both Hub and Spoke contracts with validation
 */
contract DeployAxelarIntegration is Script {
    struct DeploymentConfig {
        address gateway;
        address gasService;
        string chainName;
        bool isHub;
        address hubHandlerAddress; // Only for spoke deployments
        string hubChainName; // Only for spoke deployments
    }

    function run() external {
        uint256 chainId = block.chainid;
        console.log("Deploying on chain ID:", chainId);

        // Determine deployment type based on environment or chain ID
        bool isHub = vm.envOr("IS_HUB_DEPLOYMENT", false);

        if (isHub) {
            deployHub();
        } else {
            deploySpoke();
        }
    }

    function deployHub() internal {
        vm.startBroadcast();

        console.log("=== DEPLOYING HUB CONTRACTS ===");

        DeploymentConfig memory config = getHubConfig();
        validateConfig(config);

        console.log("Configuration:");
        console.log("Gateway:", config.gateway);
        console.log("Gas Service:", config.gasService);
        console.log("Chain Name:", config.chainName);

        // Deploy PeridotForwarder
        console.log("\n1. Deploying PeridotForwarder...");
        PeridotForwarder forwarder = new PeridotForwarder();
        console.log("PeridotForwarder deployed to:", address(forwarder));

        // Deploy PeridotHubHandler
        console.log("\n2. Deploying PeridotHubHandler...");
        PeridotHubHandler hubHandler = new PeridotHubHandler(
            config.gateway,
            config.gasService,
            address(forwarder)
        );
        console.log("PeridotHubHandler deployed to:", address(hubHandler));

        // Validate deployment
        console.log("\n3. Validating deployment...");
        validateHubDeployment(hubHandler, forwarder, config);

        console.log("\n=== HUB DEPLOYMENT COMPLETE ===");
        printHubNextSteps(address(hubHandler), address(forwarder));

        vm.stopBroadcast();
    }

    function deploySpoke() internal {
        vm.startBroadcast();

        console.log("=== DEPLOYING SPOKE CONTRACTS ===");

        DeploymentConfig memory config = getSpokeConfig();
        validateConfig(config);

        console.log("Configuration:");
        console.log("Gateway:", config.gateway);
        console.log("Gas Service:", config.gasService);
        console.log("Chain Name:", config.chainName);
        console.log("Hub Chain:", config.hubChainName);
        console.log("Hub Handler:", config.hubHandlerAddress);

        // Deploy PeridotSpoke
        console.log("\n1. Deploying PeridotSpoke...");
        string memory hubHandlerStr = Strings.toHexString(
            uint256(uint160(config.hubHandlerAddress)),
            20
        );
        PeridotSpoke spoke = new PeridotSpoke(
            config.gateway,
            config.gasService,
            config.hubChainName,
            hubHandlerStr
        );
        console.log("PeridotSpoke deployed to:", address(spoke));

        // Validate deployment
        console.log("\n2. Validating deployment...");
        validateSpokeDeployment(spoke, config);

        console.log("\n=== SPOKE DEPLOYMENT COMPLETE ===");
        printSpokeNextSteps(address(spoke));

        vm.stopBroadcast();
    }

    function getHubConfig() internal view returns (DeploymentConfig memory) {
        return
            DeploymentConfig({
                gateway: vm.envOr(
                    "AXELAR_GATEWAY_HUB",
                    address(0x4D147dCb984e6affEEC47e44293DA442580A3Ec0)
                ),
                gasService: vm.envOr(
                    "AXELAR_GAS_SERVICE_HUB",
                    address(0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6)
                ),
                chainName: vm.envOr(
                    "HUB_CHAIN_NAME",
                    string("ethereum-sepolia")
                ),
                isHub: true,
                hubHandlerAddress: address(0),
                hubChainName: ""
            });
    }

    function getSpokeConfig() internal view returns (DeploymentConfig memory) {
        return
            DeploymentConfig({
                gateway: vm.envOr(
                    "AXELAR_GATEWAY_SPOKE",
                    address(0xe1cE95479C84e9809269227C7F8524aE051Ae77a)
                ),
                gasService: vm.envOr(
                    "AXELAR_GAS_SERVICE_SPOKE",
                    address(0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6)
                ),
                chainName: vm.envOr("SPOKE_CHAIN_NAME", string("polygon-amoy")),
                isHub: false,
                hubHandlerAddress: vm.envOr("HUB_HANDLER_ADDRESS", address(0)),
                hubChainName: vm.envOr(
                    "HUB_CHAIN_NAME",
                    string("ethereum-sepolia")
                )
            });
    }

    function validateConfig(DeploymentConfig memory config) internal pure {
        require(config.gateway != address(0), "Invalid gateway address");
        require(config.gasService != address(0), "Invalid gas service address");
        require(bytes(config.chainName).length > 0, "Invalid chain name");

        if (!config.isHub) {
            require(
                config.hubHandlerAddress != address(0),
                "Invalid hub handler address"
            );
            require(
                bytes(config.hubChainName).length > 0,
                "Invalid hub chain name"
            );
        }
    }

    function validateHubDeployment(
        PeridotHubHandler hubHandler,
        PeridotForwarder forwarder,
        DeploymentConfig memory config
    ) internal view {
        require(
            address(hubHandler.gateway()) == config.gateway,
            "Gateway address mismatch"
        );
        require(
            hubHandler.gasService() == config.gasService,
            "Gas service address mismatch"
        );
        require(
            hubHandler.peridotForwarder() == address(forwarder),
            "Forwarder address mismatch"
        );
        require(hubHandler.owner() == msg.sender, "Owner address mismatch");

        console.log(" All validations passed");
    }

    function validateSpokeDeployment(
        PeridotSpoke spoke,
        DeploymentConfig memory config
    ) internal view {
        require(
            address(spoke.gateway()) == config.gateway,
            "Gateway address mismatch"
        );
        require(
            address(spoke.gasService()) == config.gasService,
            "Gas service address mismatch"
        );
        require(
            keccak256(abi.encodePacked(spoke.hubChainName())) ==
                keccak256(abi.encodePacked(config.hubChainName)),
            "Hub chain name mismatch"
        );
        require(spoke.owner() == msg.sender, "Owner address mismatch");

        console.log(" All validations passed");
    }

    function printHubNextSteps(
        address hubHandler,
        address forwarder
    ) internal view {
        console.log("\nNext Steps for Hub Deployment:");
        console.log("1. Configure pToken mappings:");
        console.log("   hubHandler.setPToken(underlying, pToken)");
        console.log("2. Deploy pTokens with forwarder address:", forwarder);
        console.log("3. Whitelist forwarder in pTokens");
        console.log(
            "4. Update spoke contracts with hub handler address:",
            hubHandler
        );
        console.log("5. Test cross-chain flow on testnet");
    }

    function printSpokeNextSteps(address spoke) internal view {
        console.log("\nNext Steps for Spoke Deployment:");
        console.log("1. Configure pToken address if needed:");
        console.log("   spoke.setPToken(underlying, pTokenAddr)");
        console.log("2. Fund contract with native tokens for gas payments");
        console.log("3. Test supply/borrow flows:");
        console.log("   spoke.supplyToPeridot(...)");
        console.log("   spoke.borrowFromPeridot(...)");
        console.log("4. Monitor transactions on AxelarScan");
        console.log("Spoke address:", spoke);
    }
}
