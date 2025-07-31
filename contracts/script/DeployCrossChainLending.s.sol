// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";
import {PeridotForwarder} from "../contracts/PeridotForwarder.sol";
import {PeridotSpokeReceiver} from "../contracts/PeridotSpokeReceiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/console.sol";

contract DeployCrossChainLending is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy PeridotForwarder on Hub
        PeridotForwarder forwarder = new PeridotForwarder();
        console.log("PeridotForwarder deployed to:", address(forwarder));

        // Deploy PeridotHubHandler on Hub
        // Replace with actual gateway address
        address hubGateway = 0x0000000000000000000000000000000000000001;
        address gasService = hubGateway; // placeholder; replace with real Axelar Gas Service address
        PeridotHubHandler hubHandler = new PeridotHubHandler(hubGateway, gasService, address(forwarder));
        console.log("PeridotHubHandler deployed to:", address(hubHandler));

        // Deploy PeridotSpoke on Spoke
        // Replace with actual gateway, hub chain name, and hub contract address
        address spokeGateway = 0x0000000000000000000000000000000000000002;
        string memory hubChainName = "HubChain";
        string memory hubHandlerStr = Strings.toHexString(uint256(uint160(address(hubHandler))), 20);
        PeridotSpoke spoke = new PeridotSpoke(spokeGateway, hubChainName, hubHandlerStr);
        console.log("PeridotSpoke deployed to:", address(spoke));

        // Deploy PeridotSpokeReceiver on Spoke
        PeridotSpokeReceiver spokeReceiver = new PeridotSpokeReceiver(spokeGateway);
        console.log("PeridotSpokeReceiver deployed to:", address(spokeReceiver));

        vm.stopBroadcast();
    }
}
