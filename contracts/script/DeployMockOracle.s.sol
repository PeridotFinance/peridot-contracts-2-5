// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../contracts/MockOracle.sol";

contract DeployMockOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockOracle oracle = new MockOracle();

        console.log("MockOracle deployed at:", address(oracle));

        vm.stopBroadcast();
    }
}
