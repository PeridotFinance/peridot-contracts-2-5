// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/PeridotStaking.sol";
import "../contracts/proxy/PeridotTransparentProxy.sol";

/// @dev Deploys PeridotStaking implementation + transparent proxy with initializer call.
contract DeployPeridotStaking is Script {
    function run() external {
        address proxyAdmin = vm.envAddress("PROXY_ADMIN");
        address owner = vm.envAddress("STAKING_OWNER");
        address stakeToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        uint256 rewardDuration = vm.envUint("REWARD_DURATION");

        require(proxyAdmin != address(0), "PROXY_ADMIN missing");
        require(owner != address(0), "STAKING_OWNER missing");
        require(stakeToken != address(0), "STAKING_TOKEN missing");
        require(rewardToken != address(0), "REWARD_TOKEN missing");
        require(rewardDuration > 0, "REWARD_DURATION missing");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        PeridotStaking impl = new PeridotStaking();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,uint256)",
            stakeToken,
            rewardToken,
            owner,
            rewardDuration
        );

        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            address(impl),
            proxyAdmin,
            initData
        );

        console2.log("PeridotStaking implementation:", address(impl));
        console2.log("PeridotStaking proxy:", address(proxy));

        vm.stopBroadcast();
    }
}
