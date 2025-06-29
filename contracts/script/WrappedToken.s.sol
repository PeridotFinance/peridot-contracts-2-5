// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ITokenBridge} from "../lib/wormhole-solidity-sdk/src/interfaces/ITokenBridge.sol";

contract CreateWrappedToken is Script {
    // Your Base Sepolia TokenBridge address:
    address constant TOKEN_BRIDGE = 0x86F55A04690fd7815A3D802bD587e83eA888B239;

    // Get hex-encoded VAA (f.e.: AQAAAAABAGKNsn30EWdX3FH2S/4OGnhKTKVSq62fXzsic7bRE5UVeVKbzbaGjRb6ULF4wAQGJ2Njfxl1shMYZ7+y798UpsQAaAfTygKB7a0nEwAAAAAAAAAAAAAAAMeiBL2/6YP82NjmHQK0ddQHP/l+AAAAAAAAAOoBAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJUC+QAAAAAAAAAAAAAAAAA3uVms/6Z+NmTS6ru3aKY1bdriGgnEwAAAAAAAAAAAAAAAPRQs4zM/c+tL5j35LtTMVGi+wDpJxQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==):
    // echo "YOUR_BASE64_STRING" | base64 --decode | xxd -p -c 1000

    // Paste the hex‑encoded VAA you fetched
    bytes vaa =
        hex"010000000001000caa23a4211b041f8e249b4f2b392a97bd7909a3b6f772b8069136375d5a1b0d5d17b84576cc5ce93864a06331a50084a88041c91925ad9a9f3c1699491b1879016807cc6c0281edac2713000000000000000000000000c7a204bdbfe983fcd8d8e61d02b475d4073ff97e00000000000000e90102000000000000000000000000dee566b3fe99f8d9934baaeedda298d5b76b88682713124d544b00000000000000000000000000000000000000000000000000000000004d79546f6b656e00000000000000000000000000000000000000000000000000";

    function run() external {
        console.log("Wrapping attested token on Base Sepolia");
        console.log(" TokenBridge:", TOKEN_BRIDGE);

        vm.startBroadcast();

        // This will deploy (or return) the wrapped ERC20 on BaseSepolia
        address wrapped = ITokenBridge(TOKEN_BRIDGE).createWrapped(vaa);
        console.log("Wrapped token deployed at:", wrapped);

        vm.stopBroadcast();
    }
}
