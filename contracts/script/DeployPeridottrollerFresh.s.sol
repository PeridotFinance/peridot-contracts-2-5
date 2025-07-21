// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PeridottrollerG7.sol";
import "../contracts/Unitroller.sol";
import "../contracts/PriceOracle.sol";

/**
 * @title DeployPeridottrollerFresh
 * @dev Fresh deployment of Unitroller + PeridottrollerG7 with proper PERIDOT assignment
 *
 * This avoids the proxy storage layout issue by deploying everything fresh.
 * Use this if the redeployment approach doesn't work.
 *
 * IMPORTANT: You'll need to update all your PToken contracts to point to this new Peridottroller
 *
 * Usage: forge script script/DeployPeridottrollerFresh.s.sol:DeployPeridottrollerFresh --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 */
contract DeployPeridottrollerFresh is Script {
    // === CONFIGURATION ===
    // Same values from your original deployment
    address constant ORACLE_ADDRESS =
        0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant PERIDOT_ADDRESS =
        0x28fE679719e740D15FC60325416bB43eAc50cD15;

    // Same configuration values as original
    uint constant closeFactorMantissa = 0.5e18; // 50%
    uint constant liquidationIncentiveMantissa = 1.08e18; // 8% bonus

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Fresh Peridottroller Deployment ===");
        console.log("Deployer/Owner:", deployer);
        console.log("PERIDOT Token:", PERIDOT_ADDRESS);
        console.log("Oracle:", ORACLE_ADDRESS);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new Unitroller (Proxy)
        console.log("\n=== Deploying Unitroller ===");
        Unitroller unitroller = new Unitroller();
        console.log("New Unitroller deployed at:", address(unitroller));
        console.log("Unitroller admin:", unitroller.admin());

        // 2. Deploy new PeridottrollerG7 (Implementation) with correct PERIDOT
        console.log("\n=== Deploying PeridottrollerG7 ===");
        PeridottrollerG7 peridotTrollerImpl = new PeridottrollerG7(
            PERIDOT_ADDRESS
        );
        console.log(
            "PeridottrollerG7 deployed at:",
            address(peridotTrollerImpl)
        );
        console.log(
            "Implementation PERIDOT:",
            peridotTrollerImpl.getPeridotAddress()
        );

        // 3. Set Implementation for Unitroller
        console.log("\n=== Connecting Proxy to Implementation ===");
        uint setImplResult = unitroller._setPendingImplementation(
            address(peridotTrollerImpl)
        );
        require(setImplResult == 0, "Failed to set pending implementation");
        console.log("Pending implementation set");

        // 4. Accept Implementation
        peridotTrollerImpl._become(unitroller);
        console.log("Implementation accepted by Unitroller");

        // 5. Get Peridottroller Proxy Interface
        PeridottrollerG7 peridotTrollerProxy = PeridottrollerG7(
            address(unitroller)
        );

        // 6. Verify PERIDOT is correctly set
        console.log("\n=== Verification ===");
        console.log(
            "Proxy implementation:",
            unitroller.peridottrollerImplementation()
        );
        console.log(
            "PERIDOT via proxy:",
            peridotTrollerProxy.getPeridotAddress()
        );

        require(
            peridotTrollerProxy.getPeridotAddress() == PERIDOT_ADDRESS,
            "PERIDOT address mismatch!"
        );
        console.log("PERIDOT address verified!");

        // 7. Initialize Peridottroller settings
        console.log("\n=== Initializing Settings ===");

        // Set Price Oracle
        uint setOracleResult = peridotTrollerProxy._setPriceOracle(
            PriceOracle(ORACLE_ADDRESS)
        );
        require(setOracleResult == 0, "Failed to set price oracle");
        console.log(" Price Oracle set to:", ORACLE_ADDRESS);

        // Set Close Factor
        uint setCloseFactorResult = peridotTrollerProxy._setCloseFactor(
            closeFactorMantissa
        );
        require(setCloseFactorResult == 0, "Failed to set close factor");
        console.log(" Close Factor set to:", closeFactorMantissa);

        // Set Liquidation Incentive
        uint setLiqIncResult = peridotTrollerProxy._setLiquidationIncentive(
            liquidationIncentiveMantissa
        );
        require(setLiqIncResult == 0, "Failed to set liquidation incentive");
        console.log(
            "Liquidation Incentive set to:",
            liquidationIncentiveMantissa
        );

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log(" NEW Unitroller (Proxy):", address(unitroller));
        console.log(
            " NEW PeridottrollerG7 (Implementation):",
            address(peridotTrollerImpl)
        );
        console.log(
            " Use this Peridottroller address:",
            address(peridotTrollerProxy)
        );
        console.log(
            " PERIDOT Token correctly set to:",
            peridotTrollerProxy.getPeridotAddress()
        );
        console.log(" Oracle:", address(peridotTrollerProxy.oracle()));
        console.log(
            " Close Factor:",
            peridotTrollerProxy.closeFactorMantissa()
        );
        console.log(
            " Liquidation Incentive:",
            peridotTrollerProxy.liquidationIncentiveMantissa()
        );

        console.log("\n=== NEXT STEPS ===");
        console.log(
            "1. Update your PToken contracts to use the new Peridottroller:"
        );
        console.log("   - Call _setPeridottroller() on each PToken");
        console.log(
            "   - New Peridottroller address:",
            address(peridotTrollerProxy)
        );
        console.log(
            "2. Set market parameters (collateral factors, borrow caps, etc.)"
        );
        console.log("3. Set PERIDOT reward speeds for each market");
        console.log("4. Test reserve factor setting with:");
        console.log("   - Use _setReserveFactor() on your PTokens");
        console.log("   - Should work now that admin is properly set");
    }
}
