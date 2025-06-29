// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../contracts/MockERc20.sol";

/**
 * @title DeployContracts
 * @dev A forge script to deploy MockERC20 token
 * Usage: forge script script/DeployERC20.s.sol:DeployERC20 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --etherscan-api-key $ARBITRUMSCAN_KEY --verify
 */
contract DeployERC20 is Script {
    function run() public {
        vm.startBroadcast();

        // Step 1: Deploy the MyToken contract (MockERC20)
        USDT myToken = new USDT(msg.sender);
        console.log("MyToken deployed at: %s", address(myToken));

        // Step 2: For testing, mint some tokens to the deployer
        myToken.mint(msg.sender, 1000000 * (10 ** 18)); // Mint 1,000,000 tokens
        console.log("Minted 1,000,000 tokens to: %s", msg.sender);

        vm.stopBroadcast();

        // Output deployment summary
        console.log("\n==== Deployment Summary ====");
        console.log("MyToken (MTK): %s", address(myToken));
    }
}
