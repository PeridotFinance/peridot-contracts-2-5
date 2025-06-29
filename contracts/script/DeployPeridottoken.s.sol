// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../contracts/Governance/Peridot.sol";

/**
 * @title DeployContracts
 * @dev A forge script to deploy MockERC20 token
 * Usage: forge script script/DeployERC20.s.sol:DeployERC20 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --etherscan-api-key $ARBITRUMSCAN_KEY --verify
 */
contract DeployPeridot is Script {
    function run() public {
        vm.startBroadcast();

        // Step 1: Deploy the MyToken contract (MockERC20)
        Peridot peridot = new Peridot(msg.sender);
        console.log("Peridot deployed at: %s", address(peridot));

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n==== Deployment Summary ====");
        console.log("Peridottoken : %s", address(peridot));
    }
}
