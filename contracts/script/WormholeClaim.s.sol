// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";

/**
 * @notice Calls receiveAndUnlock on the destination chain using a signed VAA.
 *
 * Minimal manual mode:
 * - Provide the VAA as hex via VAA_HEX (0x...).
 *
 * Optional auto-fetch mode (requires --ffi):
 * - Provide VAA_URL and the script will `curl` it and parse the response as raw bytes hex.
 *   This mode is intentionally not the default to avoid requiring FFI.
 *
 * Env vars:
 * - PRIVATE_KEY: tx sender key
 * - BRIDGE: PeridotBridgeEvm address on destination chain
 * - VAA_HEX: bytes hex string (0x...)  (required unless VAA_URL is used)
 * - VAA_URL: optional URL that returns 0x-prefixed hex bytes for the VAA
 */
contract WormholeClaim is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bridgeAddr = vm.envAddress("BRIDGE");

        bytes memory vaa;

        string memory url = vm.envOr("VAA_URL", string(""));
        if (bytes(url).length > 0) {
            string[] memory cmds = new string[](3);
            cmds[0] = "bash";
            cmds[1] = "-lc";
            cmds[2] = string.concat("curl -s '", url, "'");
            bytes memory out = vm.ffi(cmds);
            // Expect out to be an ASCII hex string like: 0x....
            vaa = vm.parseBytes(string(out));
        } else {
            string memory vaaHex = vm.envString("VAA_HEX");
            vaa = vm.parseBytes(vaaHex);
        }

        vm.startBroadcast(pk);
        PeridotBridgeEvm(payable(bridgeAddr)).receiveAndUnlock(vaa);
        vm.stopBroadcast();

        console2.log("receiveAndUnlock submitted");
        console2.log("VAA length:", vaa.length);
    }
}
