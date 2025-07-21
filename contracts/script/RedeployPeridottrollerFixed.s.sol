// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PeridottrollerG7Fixed.sol";
import "../contracts/Unitroller.sol";

/**
 * @title UpgradeAndFixPeridotAddress
 * @dev Upgrades the Peridottroller implementation to PeridottrollerG7Fixed and sets the PERIDOT address.
 *
 * This script performs a two-step fix for the storage layout issue:
 * 1. Deploys the new `PeridottrollerG7Fixed` contract.
 * 2. Sets this new contract as the implementation for the Unitroller proxy.
 * 3. Calls the new `_setPeridotAddress()` function through the proxy to correctly set the PERIDOT address in the proxy's storage.
 *
 * Usage: forge script script/RedeployPeridottrollerFixed.s.sol:UpgradeAndFixPeridotAddress --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 */
contract UpgradeAndFixPeridotAddress is Script {
    // === CONFIGURATION ===
    address constant EXISTING_UNITROLLER =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant PERIDOT_ADDRESS =
        0x28fE679719e740D15FC60325416bB43eAc50cD15;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log(
            "=== Upgrading to PeridottrollerG7Fixed and Fixing PERIDOT Address ==="
        );
        console.log("Deployer:", deployer);
        console.log("Existing Unitroller:", EXISTING_UNITROLLER);
        console.log("Target PERIDOT Token:", PERIDOT_ADDRESS);

        vm.startBroadcast(deployerPrivateKey);

        // --- Step 1: Get Contract Instances ---
        Unitroller unitroller = Unitroller(payable(EXISTING_UNITROLLER));
        PeridottrollerG7Fixed proxy = PeridottrollerG7Fixed(
            EXISTING_UNITROLLER
        );

        console.log("\n=== Current State ===");
        console.log("Unitroller Admin:", unitroller.admin());
        console.log(
            "Current Implementation:",
            unitroller.peridottrollerImplementation()
        );
        console.log("Current PERIDOT (via proxy):", proxy.getPeridotAddress());

        require(
            unitroller.admin() == deployer,
            "Deployer must be Unitroller admin"
        );

        // --- Step 2: Deploy new PeridottrollerG7Fixed implementation ---
        console.log("\n=== Deploying New Implementation ===");
        // We still pass PERIDOT_ADDRESS to the constructor for consistency,
        // even though we'll set it via the proxy's context later.
        PeridottrollerG7Fixed newImpl = new PeridottrollerG7Fixed(
            PERIDOT_ADDRESS
        );
        console.log("New PeridottrollerG7Fixed deployed at:", address(newImpl));

        // --- Step 3: Set the new implementation ---
        console.log("\n=== Updating Unitroller Implementation ===");
        unitroller._setPendingImplementation(address(newImpl));
        console.log("Pending implementation set to:", address(newImpl));

        newImpl._become(unitroller);
        console.log(
            "New implementation accepted by new implementation contract."
        );

        console.log(
            "New implementation address in Unitroller:",
            unitroller.peridottrollerImplementation()
        );

        // --- Step 4: Call the setter to fix the PERIDOT address in proxy storage ---
        console.log("\n=== Setting PERIDOT address in Proxy Storage ===");
        uint256 setResult = proxy._setPeridotAddress(PERIDOT_ADDRESS);
        require(setResult == 0, "Failed to set PERIDOT address");
        console.log(
            "Called _setPeridotAddress on proxy with:",
            PERIDOT_ADDRESS
        );

        // --- Step 5: Final Verification ---
        console.log("\n=== Final Verification ===");
        address peridotViaProxy = proxy.getPeridotAddress();
        console.log("Final PERIDOT Address (via proxy):", peridotViaProxy);

        if (peridotViaProxy == PERIDOT_ADDRESS) {
            console.log("\n SUCCESS: PERIDOT address fixed successfully!");
        } else {
            console.log("\n FAILED: PERIDOT address is still incorrect.");
        }

        vm.stopBroadcast();

        console.log("\n=== Summary ===");
        console.log("Unitroller (Proxy):", EXISTING_UNITROLLER);
        console.log("New PeridottrollerG7Fixed Impl:", address(newImpl));
        console.log("Expected PERIDOT:", PERIDOT_ADDRESS);
        console.log("Actual PERIDOT (via proxy):", peridotViaProxy);
    }
}
