// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {LayerZeroV2BscTestnet, LayerZeroV2BasesepTestnet, LayerZeroV2MonadTestnet} from "lz-address-book/generated/LZAddresses.sol";

interface IOAppSetPeer {
    function setPeer(uint32 _eid, bytes32 _peer) external;
}

/**
 * @title ConfigurePOFTPeers
 * @notice Wires BSC testnet <-> Base Sepolia P_OFTAdapter proxies as trusted peers.
 * @dev Run once after deploying proxies on both chains.
 */
contract ConfigurePOFTPeers is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address bscAdapter = vm.envAddress("BSC_TESTNET_ADAPTER");
        address baseAdapter = vm.envAddress("BASE_SEPOLIA_ADAPTER");

        vm.startBroadcast(pk);

        // Determine which chain we're on and configure the local adapter to trust the remote adapter.
        if (block.chainid == LayerZeroV2BscTestnet.CHAIN_ID) {
            IOAppSetPeer(bscAdapter).setPeer(
                LayerZeroV2BasesepTestnet.EID,
                _addressToBytes32(baseAdapter)
            );
        } else if (block.chainid == LayerZeroV2BasesepTestnet.CHAIN_ID) {
            IOAppSetPeer(baseAdapter).setPeer(
                LayerZeroV2BscTestnet.EID,
                _addressToBytes32(bscAdapter)
            );
        } else {
            revert("Unsupported chain: use BSC testnet or Base Sepolia");
        }

        vm.stopBroadcast();
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
