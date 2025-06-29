// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/FeedsPriceOracle.sol";

contract DeployFeedsPriceOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Default stale threshold of 1 hour (3600 seconds)
        uint256 defaultStaleThreshold = 3600;

        // Deploy the FeedsPriceOracle
        FeedsPriceOracle oracle = new FeedsPriceOracle(defaultStaleThreshold);

        console.log("FeedsPriceOracle deployed at:", address(oracle));
        console.log(
            "Default stale threshold:",
            defaultStaleThreshold,
            "seconds"
        );
        console.log("Owner:", oracle.getOwner());

        vm.stopBroadcast();
    }
}
