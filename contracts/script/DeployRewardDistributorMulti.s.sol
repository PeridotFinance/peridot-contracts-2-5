// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/RewardDistributorMulti.sol";
import "../contracts/boosted/RewardDistributorMultiProxy.sol";

/// @dev Deploys RewardDistributorMulti implementation + proxy. Configure initial owner via env or constants.
contract DeployRewardDistributorMulti is Script {
    function run() external {
        address admin = 0xCED23360932B80d18fdEAEAa573202E80A584804;
        require(admin != address(0), "REWARD_ADMIN missing");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy implementation
        RewardDistributorMulti impl = new RewardDistributorMulti(admin);

        // No initializer needed; owner set via constructor. Proxy delegates to impl.
        bytes memory initData = "";
        RewardDistributorMultiProxy proxy = new RewardDistributorMultiProxy(
            address(impl),
            admin,
            initData
        );

        console2.log("RewardDistributorMulti implementation:", address(impl));
        console2.log("RewardDistributorMulti proxy:", address(proxy));
        vm.stopBroadcast();
    }
}
