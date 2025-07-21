// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20Delegator.sol";

contract FixAdminAndReserveFactor is Script {
    // Replace these with your actual addresses
    address payable constant PUSDT_ADDRESS =
        payable(0xEDdC65ECaF2e67c301a01fDc1da6805084f621D0); // Your pUSDT address
    address payable constant PUSDC_ADDRESS =
        payable(0x46de2583b5CCC7C8169608f5cA168389f1e4b5b9); // Your pUSDC address

    // Desired reserve factor (e.g., 15% = 0.15 * 1e18)
    uint256 constant RESERVE_FACTOR = 0.15e18; // 15%

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Fix pUSDT
        fixPToken(PUSDT_ADDRESS, "pUSDT", deployer);

        // Fix pUSDC
        fixPToken(PUSDC_ADDRESS, "pUSDC", deployer);

        vm.stopBroadcast();
    }

    function fixPToken(
        address payable pTokenAddress,
        string memory name,
        address newAdmin
    ) internal {
        PErc20Delegator pToken = PErc20Delegator(pTokenAddress);

        console.log("=== Fixing", name, "===");
        console.log("Current admin:", pToken.admin());
        console.log("New admin will be:", newAdmin);

        // Method 1: If you're the current admin, directly set reserve factor
        try pToken._setReserveFactor(RESERVE_FACTOR) returns (uint result) {
            if (result == 0) {
                console.log(" Successfully set reserve factor to 15%");
                return;
            } else {
                console.log(
                    " Failed to set reserve factor, error code:",
                    result
                );
            }
        } catch {
            console.log(" Not authorized to set reserve factor directly");
        }

        // Method 2: If current admin is wrong, try to become admin
        if (pToken.admin() != newAdmin) {
            console.log("Admin is incorrect, attempting to fix...");

            // Check if you're the pending admin
            if (pToken.pendingAdmin() == newAdmin) {
                console.log("You are pending admin, accepting admin role...");
                try pToken._acceptAdmin() returns (uint result) {
                    if (result == 0) {
                        console.log(" Successfully accepted admin role");
                        // Now set reserve factor
                        uint256 reserveResult = pToken._setReserveFactor(
                            RESERVE_FACTOR
                        );
                        if (reserveResult == 0) {
                            console.log(
                                " Successfully set reserve factor to 15%"
                            );
                        } else {
                            console.log(
                                " Failed to set reserve factor, error code:",
                                reserveResult
                            );
                        }
                    } else {
                        console.log(
                            " Failed to accept admin, error code:",
                            result
                        );
                    }
                } catch {
                    console.log(" Failed to accept admin role");
                }
            } else {
                console.log(
                    " You are not the pending admin. Current admin needs to set you as pending admin first."
                );
                console.log(
                    "Current admin should call: _setPendingAdmin(",
                    newAdmin,
                    ")"
                );
            }
        }
    }
}
