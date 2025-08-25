// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PeridotProxyAdmin} from "../contracts/proxy/PeridotProxyAdmin.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import "forge-std/console.sol";

contract DeploySpoke is Script {
    function run() external {
        vm.startBroadcast();

        // --- CONFIGURATION ---
        // Get addresses from environment variables or use defaults for testing
        address spokeGateway = vm.envOr(
            "AXELAR_GATEWAY_SPOKE",
            0xe1cE95479C84e9809269227C7F8524aE051Ae77a
        );
        address gasService = vm.envOr(
            "AXELAR_GAS_SERVICE_SPOKE",
            0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6
        );

        string memory hubChainName = vm.envOr(
            "HUB_CHAIN_NAME",
            string("binance")
        );
        address hubHandlerAddress = vm.envOr(
            "HUB_HANDLER_ADDRESS",
            0x91b2cb19Ce8072296732349ca26F78ad60c4FF40
        );

        // Validate addresses
        require(spokeGateway != address(0), "Invalid gateway address");
        require(gasService != address(0), "Invalid gas service address");
        require(hubHandlerAddress != address(0), "Invalid hub handler address");
        require(bytes(hubChainName).length > 0, "Invalid hub chain name");

        console.log("Deploying with configuration:");
        console.log("Spoke Gateway:", spokeGateway);
        console.log("Gas Service:", gasService);
        console.log("Hub Chain:", hubChainName);
        console.log("Hub Handler:", hubHandlerAddress);

        // Deploy PeridotSpoke on Spoke via transparent proxy
        string memory hubHandlerStr = Strings.toHexString(
            uint256(uint160(hubHandlerAddress)),
            20
        );
        // Deploy proxy admin
        PeridotProxyAdmin proxyAdmin = new PeridotProxyAdmin(msg.sender);
        console.log("ProxyAdmin:", address(proxyAdmin));

        // Deploy implementation
        PeridotSpoke spokeImpl = new PeridotSpoke();
        console.log("Spoke implementation:", address(spokeImpl));

        // Prepare initializer data
        bytes memory initData = abi.encodeWithSelector(
            PeridotSpoke.initialize.selector,
            spokeGateway,
            gasService,
            hubChainName,
            hubHandlerStr,
            msg.sender
        );

        // Deploy proxy with initializer
        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            address(spokeImpl),
            address(proxyAdmin),
            initData
        );
        PeridotSpoke spoke = PeridotSpoke(payable(address(proxy)));
        console.log("PeridotSpoke (proxy) deployed to:", address(spoke));

        // Validate deployment
        require(
            address(spoke.gateway()) == spokeGateway,
            "Gateway address mismatch"
        );
        require(
            address(spoke.gasService()) == gasService,
            "Gas service address mismatch"
        );
        require(
            keccak256(abi.encodePacked(spoke.hubChainName())) ==
                keccak256(abi.encodePacked(hubChainName)),
            "Hub chain name mismatch"
        );

        console.log("Deployment validated successfully!");

        vm.stopBroadcast();
    }
}
