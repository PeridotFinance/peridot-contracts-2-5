// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20Delegator.sol";

contract CheckAdmin is Script {
    // Replace these with your actual PToken addresses
    address payable constant PUSDT_ADDRESS =
        payable(0xEDdC65ECaF2e67c301a01fDc1da6805084f621D0); // Your pUSDT address
    address payable constant PUSDC_ADDRESS =
        payable(0x46de2583b5CCC7C8169608f5cA168389f1e4b5b9); // Your pUSDC address

    function run() public view {
        PErc20Delegator pUSDT = PErc20Delegator(PUSDT_ADDRESS);
        PErc20Delegator pUSDC = PErc20Delegator(PUSDC_ADDRESS);

        console.log("=== Admin Check Results ===");
        console.log("pUSDT Admin:", pUSDT.admin());
        console.log("pUSDC Admin:", pUSDC.admin());
        console.log("Your Address:", msg.sender);

        // Check if there's a pending admin
        console.log("pUSDT Pending Admin:", pUSDT.pendingAdmin());
        console.log("pUSDC Pending Admin:", pUSDC.pendingAdmin());
    }
}
