// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";

/**
 * @title DeployPeridotBridgeMonadTestnet
 * @notice Deploys PeridotBridgeEvm on Monad Testnet
 */
contract DeployPeridotBridgeMonadTestnet is Script {
    function run() external {
        // Monad Testnet Configuration
        address tokenP = 0x28fE679719e740D15FC60325416bB43eAc50cD15; // $P on Monad Testnet

        // TODO: Update with actual Wormhole Core address for Monad Testnet
        // Check: https://docs.wormhole.com/wormhole/reference/constants
        address wormholeCore = 0xBB73cB66C26740F31d1FabDC6b7A46a038A300dd; // PLACEHOLDER - MUST UPDATE

        // Optional: Wormhole Executor address (only needed if using lockAndSendAndRequestExecution)
        address executor = address(0); // PLACEHOLDER - set to Executor address for Monad testnet when available

        // Wormhole chain ID for Monad Testnet
        // TODO: Confirm with Wormhole team (likely 10143 or custom)
        uint16 thisChainId = 48; // Monad Testnet chain ID

        address admin = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;

        require(
            wormholeCore != address(0),
            "UPDATE WORMHOLE CORE ADDRESS FIRST"
        );

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        PeridotBridgeEvm bridge = new PeridotBridgeEvm(
            tokenP,
            wormholeCore,
            executor,
            thisChainId,
            admin
        );

        console2.log("=== MONAD TESTNET DEPLOYMENT ===");
        console2.log("PeridotBridgeEvm deployed at:", address(bridge));
        console2.log("$P Token:", tokenP);
        console2.log("Wormhole Core:", wormholeCore);
        console2.log("Chain ID:", thisChainId);

        console2.log("\n=== Next Steps ===");
        console2.log(
            "1. Fund bridge with $P inventory (transfer to:",
            address(bridge),
            ")"
        );
        console2.log("2. Set trusted emitter for BNB Testnet:");
        console2.log(
            "   cast send",
            address(bridge),
            '"setTrustedEmitter(uint16,bytes32)" 4 <BNB_BRIDGE_EMITTER>'
        );
        console2.log("3. Set rate limits:");
        console2.log(
            "   cast send",
            address(bridge),
            '"setRateLimit(uint16,bool,uint256,uint256)" 4 true 1000000000000000000000 1000000000000000000'
        );
        console2.log("4. Test with small transfer to BNB Testnet");

        vm.stopBroadcast();
    }
}
