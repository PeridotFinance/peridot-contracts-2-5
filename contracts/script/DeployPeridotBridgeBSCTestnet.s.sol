// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";

/**
 * @title DeployPeridotBridgeBSCTestnet
 * @notice Deploys PeridotBridgeEvm on BNB (BSC) Testnet
 */
contract DeployPeridotBridgeBSCTestnet is Script {
    function run() external {
        // BSC Testnet Configuration
        address tokenP = 0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed; // $P on BSC Testnet

        // Wormhole Core on BSC Testnet
        // Source: https://docs.wormhole.com/wormhole/reference/constants
        address wormholeCore = 0x68605AD7b15c732a30b1BbC62BE8F2A509D74b4D; // BSC Testnet Wormhole Core

        // Optional: Wormhole Executor address (only needed if using lockAndSendAndRequestExecution)
        address executor = address(0); // PLACEHOLDER - set to Executor address for BSC testnet when available

        // Wormhole chain ID for BSC
        uint16 thisChainId = 4; // BSC (both mainnet and testnet use same Wormhole chain ID)

        address admin = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        PeridotBridgeEvm bridge = new PeridotBridgeEvm(
            tokenP,
            wormholeCore,
            executor,
            thisChainId,
            admin
        );

        console2.log("=== BSC TESTNET DEPLOYMENT ===");
        console2.log("PeridotBridgeEvm deployed at:", address(bridge));
        console2.log("$P Token:", tokenP);
        console2.log("Wormhole Core:", wormholeCore);
        console2.log("Chain ID (Wormhole):", thisChainId);

        console2.log("\n=== Next Steps ===");
        console2.log(
            "1. Fund bridge with $P inventory (transfer to:",
            address(bridge),
            ")"
        );
        console2.log("2. Set trusted emitter for Monad Testnet:");
        console2.log(
            "   cast send",
            address(bridge),
            '"setTrustedEmitter(uint16,bytes32)" 10143 <MONAD_BRIDGE_EMITTER>'
        );
        console2.log("3. Set rate limits:");
        console2.log(
            "   cast send",
            address(bridge),
            '"setRateLimit(uint16,bool,uint256,uint256)" 10143 true 1000000000000000000000 1000000000000000000'
        );
        console2.log("4. Test with small transfer to Monad Testnet");

        vm.stopBroadcast();
    }
}
