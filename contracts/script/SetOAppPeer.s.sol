// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

interface IOAppSetPeer {
    function setPeer(uint32 _eid, bytes32 _peer) external;
}

/**
 * @title SetOAppPeer
 * @notice Sets a single LayerZero peer for an OApp/OFT adapter.
 *
 * Env vars:
 * - PRIVATE_KEY      (uint)
 * - LOCAL_OAPP       (address)  // local adapter/proxy address
 * - REMOTE_EID       (uint)     // remote LayerZero EID (e.g. Solana devnet = 40168)
 * - REMOTE_PEER      (bytes32)  // remote peer as bytes32 (EVM address padded or Solana pubkey bytes)
 */
contract SetOAppPeer is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address local = vm.envAddress("LOCAL_OAPP");
        uint32 remoteEid = uint32(vm.envUint("REMOTE_EID"));
        bytes32 remotePeer = vm.envBytes32("REMOTE_PEER");

        vm.startBroadcast(pk);
        IOAppSetPeer(local).setPeer(remoteEid, remotePeer);
        vm.stopBroadcast();
    }
}
