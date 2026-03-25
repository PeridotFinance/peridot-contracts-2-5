// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AtomicMarginExecutor} from "../contracts/margin/AtomicMarginExecutor.sol";

contract DeployAtomicMarginExecutor is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address configSource = vm.envAddress("MARGIN_CONFIG_SOURCE");

        console.log("Deploying AtomicMarginExecutor with config source:", configSource);

        vm.startBroadcast(deployerKey);
        AtomicMarginExecutor executor = new AtomicMarginExecutor(configSource);
        vm.stopBroadcast();

        console.log("AtomicMarginExecutor deployed:", address(executor));
    }
}
