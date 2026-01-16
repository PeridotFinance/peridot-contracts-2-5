// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/bridge/PeridotBridgeEvm.sol";

/**
 * @notice Approves $P to the bridge and calls lockAndSend on the source chain.
 *
 * Env vars:
 * - PRIVATE_KEY: sender key
 * - BRIDGE: PeridotBridgeEvm address on source chain
 * - DST_CHAIN: Wormhole chain id of destination (e.g. 4 for BNB)
 * - DST_RECIPIENT: bytes32 recipient (e.g. 0x0000.. + 20-byte EVM address)
 * - AMOUNT: uint256 amount of tokenP
 * - NONCE: uint32
 * - DEADLINE: uint64 unix timestamp
 * - MAX_FEE_BPS: uint256
 * - REFUND_ADDRESS: bytes32 (optional, default 0)
 */
contract WormholeLockAndSend is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bridgeAddr = vm.envAddress("BRIDGE");

        uint16 dstChain = uint16(vm.envUint("DST_CHAIN"));
        bytes32 dstRecipient = vm.envBytes32("DST_RECIPIENT");
        uint256 amount = vm.envUint("AMOUNT");
        uint32 nonce = uint32(vm.envUint("NONCE"));
        uint64 deadline = uint64(vm.envUint("DEADLINE"));
        uint256 maxFeeBps = vm.envUint("MAX_FEE_BPS");

        bytes32 refundAddress;
        if (vm.envOr("REFUND_ADDRESS", bytes32(0)) != bytes32(0)) {
            refundAddress = vm.envBytes32("REFUND_ADDRESS");
        }

        PeridotBridgeEvm bridge = PeridotBridgeEvm(payable(bridgeAddr));
        IERC20 tokenP = bridge.tokenP();

        vm.startBroadcast(pk);

        // Approve exact amount for this transfer (or switch to max allowance if desired).
        tokenP.approve(bridgeAddr, amount);

        uint256 fee = bridge.wormhole().messageFee();
        uint64 seq = bridge.lockAndSend{value: fee}(
            dstChain,
            dstRecipient,
            amount,
            nonce,
            deadline,
            maxFeeBps,
            refundAddress
        );

        console2.log("lockAndSend sequence:", seq);
        console2.log("wormhole messageFee paid:", fee);
        console2.log("dstChain:", dstChain);
        console2.logBytes32(dstRecipient);

        vm.stopBroadcast();
    }
}
