// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20Delegator.sol";

/**
 * @title SetReserveFactor
 * @dev Sets the reserve factor for deployed PToken contracts
 *
 * Usage: forge script script/SetReserveFactor.s.sol:SetReserveFactor --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 */
contract SetReserveFactor is Script {
    // === CONFIGURATION ===
    address payable constant PUSDT_ADDRESS =
        payable(0xEDdC65ECaF2e67c301a01fDc1da6805084f621D0);
    address payable constant PUSDC_ADDRESS =
        payable(0x46de2583b5CCC7C8169608f5cA168389f1e4b5b9);

    // Desired reserve factor (e.g., 15% = 0.15 * 1e18)
    uint256 constant RESERVE_FACTOR_MANTISSA = 0.15e18; // 15%

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Setting Reserve Factor ===");
        console.log("Deployer:", deployer);
        console.log("Reserve Factor:", RESERVE_FACTOR_MANTISSA, "(15%)");

        vm.startBroadcast(deployerPrivateKey);

        // Set reserve factor for pUSDT
        console.log("\n=== Setting pUSDT Reserve Factor ===");
        setReserveFactorForToken(PUSDT_ADDRESS, "pUSDT");

        // Set reserve factor for pUSDC
        console.log("\n=== Setting pUSDC Reserve Factor ===");
        setReserveFactorForToken(PUSDC_ADDRESS, "pUSDC");

        vm.stopBroadcast();

        console.log("\n=== Summary ===");
        console.log("Reserve factor set to 15% for both tokens");
        console.log("This means 15% of interest goes to reserves");
        console.log("85% of interest goes to suppliers");
    }

    function setReserveFactorForToken(
        address payable pTokenAddress,
        string memory tokenName
    ) internal {
        PErc20Delegator pToken = PErc20Delegator(pTokenAddress);

        // Check current admin
        address currentAdmin = pToken.admin();
        console.log(tokenName, "current admin:", currentAdmin);
        console.log("Transaction sender:", msg.sender);

        // Check current reserve factor
        uint256 currentReserveFactor = pToken.reserveFactorMantissa();
        console.log(tokenName, "current reserve factor:", currentReserveFactor);

        // Set new reserve factor
        try pToken._setReserveFactor(RESERVE_FACTOR_MANTISSA) returns (
            uint result
        ) {
            if (result == 0) {
                console.log(
                    tokenName,
                    "reserve factor updated successfully"
                );
                console.log("   New reserve factor:", RESERVE_FACTOR_MANTISSA);
            } else {
                console.log(tokenName, "failed with error code:", result);
                if (result == 1) {
                    console.log("   Error: Unauthorized (caller is not admin)");
                } else {
                    console.log("   Error: Unknown error code");
                }
            }
        } catch Error(string memory reason) {
            console.log(tokenName, "failed with reason:", reason);
        } catch {
            console.log(tokenName, "failed with unknown error");
        }

        // Verify the change
        uint256 newReserveFactor = pToken.reserveFactorMantissa();
        console.log(tokenName, "final reserve factor:", newReserveFactor);
    }
}
