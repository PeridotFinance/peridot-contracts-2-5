// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";

/**
 * @title DeployPeridotBridge
 * @notice Deploys PeridotBridgeEvm on an EVM chain
 * @dev Update the chain-specific addresses before deployment
 */
contract DeployPeridotBridge is Script {
    function run() external {
        // ========== CONFIGURATION (Update per chain) ==========

        // Monad Mainnet
        address tokenP = 0x96650BebC549456F253974c11Fc6cBE28172A2d2;
        address wormholeCore = 0x0000000000000000000000000000000000000000; // TODO: Get Monad Wormhole Core address
        address executor = address(0); // Optional: set if using lockAndSendAndRequestExecution
        uint16 thisChainId = 143; // Wormhole chain ID for Monad (TODO: Confirm with Wormhole)
        address admin = 0xCED23360932B80d18fdEAEAa573202E80A584804;

        // If deploying on BNB Mainnet instead:
        // address tokenP = 0x96650BebC549456F253974c11Fc6cBE28172A2d2;
        // address wormholeCore = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B; // BNB Wormhole Core
        // uint16 thisChainId = 4; // Wormhole chain ID for BNB

        // ========== DEPLOYMENT ==========

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        PeridotBridgeEvm bridge = new PeridotBridgeEvm(
            tokenP,
            wormholeCore,
            executor,
            thisChainId,
            admin
        );

        console2.log("PeridotBridgeEvm deployed at:", address(bridge));
        console2.log("Chain ID:", thisChainId);
        console2.log("$P Token:", tokenP);
        console2.log("Wormhole Core:", wormholeCore);

        console2.log("\n=== Next Steps ===");
        console2.log("1. Fund bridge with $P inventory:");
        console2.log("   Transfer $P to:", address(bridge));
        console2.log("2. Set trusted emitters for remote chains:");
        console2.log("   bridge.setTrustedEmitter(chainId, emitterBytes32)");
        console2.log("3. Configure rate limits:");
        console2.log(
            "   bridge.setRateLimit(chainId, isOutbound, capacity, refillRate)"
        );
        console2.log("4. (Optional) Set protocol fee:");
        console2.log("   bridge.setProtocolFee(feeBps)");

        vm.stopBroadcast();
    }
}
