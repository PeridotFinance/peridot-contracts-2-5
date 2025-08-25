// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";
import {PeridotProxyAdmin} from "../contracts/proxy/PeridotProxyAdmin.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import "forge-std/console.sol";

contract DeployHub is Script {
    function run() external {
        vm.startBroadcast();

        // --- CONFIGURATION ---
        address hubGateway = vm.envOr(
            "AXELAR_GATEWAY_HUB",
            0x4D147dCb984e6affEEC47e44293DA442580A3Ec0
        );
        address gasService = vm.envOr(
            "AXELAR_GAS_SERVICE_HUB",
            0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6
        );

        // Validate addresses
        require(hubGateway != address(0), "Invalid gateway address");
        require(gasService != address(0), "Invalid gas service address");

        console.log("Deploying PeridotHubHandler (proxy) with configuration:");
        console.log("Hub Gateway:", hubGateway);
        console.log("Gas Service:", gasService);

        // Deploy proxy admin
        PeridotProxyAdmin proxyAdmin = new PeridotProxyAdmin(msg.sender);
        console.log("ProxyAdmin:", address(proxyAdmin));

        // Deploy implementation (logic)
        PeridotHubHandler hubImpl = new PeridotHubHandler();
        console.log("Hub implementation:", address(hubImpl));

        // Prepare initialization calldata
        bytes memory initData = abi.encodeWithSelector(
            PeridotHubHandler.initialize.selector,
            hubGateway,
            gasService,
            msg.sender
        );

        // Deploy proxy with initializer
        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            address(hubImpl),
            address(proxyAdmin),
            initData
        );
        PeridotHubHandler hubHandler = PeridotHubHandler(
            payable(address(proxy))
        );
        console.log(
            "PeridotHubHandler (proxy) deployed to:",
            address(hubHandler)
        );

        // Validate deployment
        require(
            address(hubHandler.gateway()) == hubGateway,
            "Gateway address mismatch"
        );
        require(
            hubHandler.gasService() == gasService,
            "Gas service address mismatch"
        );
        require(hubHandler.owner() == msg.sender, "Owner address mismatch");

        console.log("Deployment validated successfully!");
        console.log("Next steps:");
        console.log(
            "1. Deploy PErc20CrossChain contracts, passing this Hub Handler address to their constructors."
        );
        console.log(
            "2. Configure pToken mappings on this Hub Handler via setPToken(underlying, pToken)."
        );
        console.log(
            "3. Configure authorized spoke contracts on this Hub Handler via setSpokeContract(chainName, spokeAddress)."
        );

        vm.stopBroadcast();
    }
}
