// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/PluginDirectOracle.sol";

contract DeployPluginDirectOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy oracle with 1 hour default stale threshold
        PluginDirectOracle oracle = new PluginDirectOracle(3600);

        console.log("PluginDirectOracle deployed at:", address(oracle));
        console.log("Owner:", oracle.getOwner());
        console.log("Default stale threshold:", oracle.defaultStaleThreshold());

        vm.stopBroadcast();
    }
}
