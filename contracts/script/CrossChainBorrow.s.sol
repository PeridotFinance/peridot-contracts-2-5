// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PeridotSpoke} from "../contracts/PeridotSpoke.sol";

/*
forge script /home/josh/peridot-ccip/contracts/script/CrossChainBorrow.s.sol:CrossChainBorrow \
  --rpc-url "$ARBITRUM_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --sig "run(address,uint256)" 0x9f048D221cC49e9C6f9C05D3EC670148108A0A01 10000
*/

contract CrossChainBorrow is Script {
    address constant PERIDOT_SPOKE_ADDRESS =
        0x367fe5290E85eE88288cc0C8Bd4f0B4696D603a7;
    uint256 constant GAS_PAYMENT = 0.01 ether;

    function run(address pTokenAddress, uint256 borrowAmount) public {
        vm.startBroadcast();
        PeridotSpoke spoke = PeridotSpoke(payable(PERIDOT_SPOKE_ADDRESS));
        spoke.borrowFromPeridot{value: GAS_PAYMENT}(
            pTokenAddress,
            borrowAmount
        );
        vm.stopBroadcast();
        console.log("SUCCESS: Cross-chain borrow submitted!");
    }
}
