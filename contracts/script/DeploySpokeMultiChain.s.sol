// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Use the v1 PeridotSpoke contract directly (constructor-based init)
import {PeridotSpoke as PeridotSpokeV1} from "../contracts/cross-chain/v1PeridotSpoke.sol";

contract DeploySpokeMultiChain is Script {
    struct ChainConfig {
        // RPC URL for the target chain (HTTP URL). Example: "https://bsc-dataseed.binance.org"
        string rpcUrl;
        // Axelar Gateway and Gas Service on the target chain
        address gateway;
        address gasService;
        // Hub chain name (Axelar chain name, e.g., "binance") and hub handler address on hub chain
        string hubChainName;
        address hubHandlerAddress; // EVM address on the hub, converted to string for Axelar
    }

    struct DeploymentResult {
        string chainRpc;
        address deployedSpoke;
        address gateway;
        address gasService;
        string hubChainName;
        string hubHandlerString;
    }

    function run() external {
        // --- FILL YOUR CONFIGS HERE ---
        // Add/remove entries as needed. No envs used; everything is manual.
        ChainConfig[] memory chains = new ChainConfig[](2);

        // EXAMPLE 1 (replace with your values)
        chains[0] = ChainConfig({
            rpcUrl: "https://base-sepolia.g.alchemy.com/v2/YW4THm0GBtkHu5w_a4encLrqervum3Xf",
            gateway: 0xe432150cce91c13a887f7D836923d5597adD8E31,
            gasService: 0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6,
            hubChainName: "binance",
            hubHandlerAddress: 0x458A4f56317d663BA5F31da21BC5BD61Fc3dcB68
        });

        // EXAMPLE 2 (replace with your values)
        chains[1] = ChainConfig({
            rpcUrl: "https://eth-sepolia.g.alchemy.com/v2/LwnPYXTlvw_VyIFhAgTBg2b_gkkKBFA6",
            gateway: 0xC249632c2D40b9001FE907806902f63038B737Ab,
            gasService: 0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6,
            hubChainName: "binance",
            hubHandlerAddress: 0x458A4f56317d663BA5F31da21BC5BD61Fc3dcB68
        });

        DeploymentResult[] memory results = new DeploymentResult[](
            chains.length
        );

        for (uint256 i = 0; i < chains.length; i++) {
            ChainConfig memory cfg = chains[i];

            require(bytes(cfg.rpcUrl).length > 0, "Missing rpcUrl");
            require(cfg.gateway != address(0), "Invalid gateway");
            require(cfg.gasService != address(0), "Invalid gasService");
            require(bytes(cfg.hubChainName).length > 0, "Invalid hubChainName");
            require(
                cfg.hubHandlerAddress != address(0),
                "Invalid hubHandlerAddress"
            );

            // Convert hub handler address to Axelar-compatible hex string (0x + 40 hex chars)
            string memory hubHandlerStr = Strings.toHexString(
                uint256(uint160(cfg.hubHandlerAddress)),
                20
            );

            // Create and select a fork for this chain's RPC, so we can broadcast to it in this single run
            uint256 forkId = vm.createFork(cfg.rpcUrl);
            vm.selectFork(forkId);

            console.log("Deploying PeridotSpoke v1 on RPC:", cfg.rpcUrl);
            console.log("  Gateway:", cfg.gateway);
            console.log("  GasService:", cfg.gasService);
            console.log("  HubChain:", cfg.hubChainName);
            console.log("  HubHandler:", hubHandlerStr);

            vm.startBroadcast();

            // Deploy v1 (constructor init)
            PeridotSpokeV1 spoke = new PeridotSpokeV1(
                cfg.gateway,
                cfg.gasService,
                cfg.hubChainName,
                hubHandlerStr
            );

            vm.stopBroadcast();

            // Validate basics
            require(
                address(spoke.getGateway()) == cfg.gateway,
                "Gateway mismatch"
            );

            // Save result
            results[i] = DeploymentResult({
                chainRpc: cfg.rpcUrl,
                deployedSpoke: address(spoke),
                gateway: cfg.gateway,
                gasService: cfg.gasService,
                hubChainName: cfg.hubChainName,
                hubHandlerString: hubHandlerStr
            });

            console.log("PeridotSpoke v1 deployed to:", address(spoke));
        }

        console.log("\n--- Deployment Summary ---");
        for (uint256 j = 0; j < results.length; j++) {
            DeploymentResult memory r = results[j];
            console.log("RPC:", r.chainRpc);
            console.log("  Spoke:", r.deployedSpoke);
            console.log("  Gateway:", r.gateway);
            console.log("  GasService:", r.gasService);
            console.log("  HubChain:", r.hubChainName);
            console.log("  HubHandler:", r.hubHandlerString);
        }
    }
}
