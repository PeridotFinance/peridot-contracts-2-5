// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PeridottrollerG7.sol";
import "../contracts/Unitroller.sol";
import "../contracts/JumpRateModelV2.sol";
import "../contracts/PriceOracle.sol"; // Interface for the oracle

/**
 * @title DeployComptroller
 * @dev Deploys the Peridot Comptroller (Unitroller proxy + Peridottroller implementation)
 *      and a default JumpRateModelV2 interest rate model.
 * Usage: forge script script/DeployComptroller.s.sol:DeployComptroller --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast --etherscan-api-key $ARBITRUMSCAN_KEY --verify
 *
 * IMPORTANT: Update the ORACLE_ADDRESS constant below with the deployed SimplePriceOracle address
 *            before running this script.
 */
contract DeployComptroller is Script {
    // !!! IMPORTANT: Replace with your deployed SimplePriceOracle address !!!
    address constant ORACLE_ADDRESS =
        0xf79b3af6954bCbeDfE0F6BE34DD1153A391E8083;
    address constant PERIDOT_ADDRESS =
        0xB911C192ed1d6428A12F2Cf8F636B00c34e68a2a;

    // Interest Rate Model Parameters (Example values, adjust as needed)
    // uint baseRatePerYear = 0.02e18; // 2%
    // uint multiplierPerYear = 0.1e18; // 10%
    // uint jumpMultiplierPerYear = 2e18; // 200%
    // uint kink = 0.8e18; // 80% utilization

    // Using Mantissa scalar 1e18 for calculations
    // 1e18; Represents 1.0 or 100%
    uint baseRatePerYear = 0.02 * 1e18; // 2% APR
    uint multiplierPerYear = 0.1 * 1e18; // 10% APR slope
    uint jumpMultiplierPerYear = 2 * 1e18; // 200% APR slope after kink
    uint kink_ = 0.8 * 1e18; // 80% utilization threshold

    // Close factor and liquidation incentive (Example values, adjust as needed)
    uint closeFactorMantissa = 0.5e18; // 50%
    uint liquidationIncentiveMantissa = 1.08e18; // 8% bonus

    address owner; // Admin/Owner address

    function setUp() public {
        /*if (
            ORACLE_ADDRESS == address(0) ||
            ORACLE_ADDRESS == 0xdefE2f4D1Bf069C7167f9b093F2ee9f01D557812
        ) {
            revert(
                "Oracle address not set. Please update the ORACLE_ADDRESS constant in the script."
            );
        }*/
        owner = msg.sender; // Default owner to deployer
    }

    function run() public {
        console.log("Deploying Comptroller and Interest Rate Model...");
        console.log("Using Oracle Address:", ORACLE_ADDRESS);
        console.log("Deployer/Owner Address:", owner);

        vm.startBroadcast();

        // 1. Deploy Unitroller (Proxy)
        Unitroller unitroller = new Unitroller();
        console.log("Unitroller (Proxy) deployed at:", address(unitroller));

        // 2. Deploy Peridottroller (Implementation)
        PeridottrollerG7 peridotTrollerImpl = new PeridottrollerG7(
            PERIDOT_ADDRESS
        );
        console.log(
            "PeridottrollerG7 (Implementation) deployed at:",
            address(peridotTrollerImpl)
        );

        // 3. Deploy JumpRateModelV2
        JumpRateModelV2 interestRateModel = new JumpRateModelV2(
            baseRatePerYear,
            multiplierPerYear,
            jumpMultiplierPerYear,
            kink_,
            owner // Owner of the interest rate model
        );
        console.log("JumpRateModelV2 deployed at:", address(interestRateModel));
        console.log("Interest Rate Model Parameters:");
        console.log("  Base Rate Per Year:", baseRatePerYear);
        console.log("  Multiplier Per Year:", multiplierPerYear);
        console.log("  Jump Multiplier Per Year:", jumpMultiplierPerYear);
        console.log("  Kink (Utilization Threshold):", kink_);

        // 4. Set Implementation for Unitroller (Proxy -> Implementation)
        // function _setPendingImplementation(address newPendingImplementation) public returns (uint)
        uint setImplResult = unitroller._setPendingImplementation(
            address(peridotTrollerImpl)
        );
        if (setImplResult != 0) {
            console.log(
                "Error setting pending implementation: %s",
                setImplResult
            );
            revert("Failed to set pending implementation");
        }
        console.log("Pending Implementation set on Unitroller.");

        // 5. Accept Implementation on Peridottroller (Implementation becomes active)
        // function _become(Unitroller unitroller) public
        peridotTrollerImpl._become(unitroller);
        console.log("PeridottrollerG7 implementation accepted by Unitroller.");

        // 6. Get Comptroller Proxy Interface (using the Unitroller address but Peridottroller ABI)
        PeridottrollerG7 peridotTrollerProxy = PeridottrollerG7(
            address(unitroller)
        );

        // 7. Initialize Comptroller settings
        console.log("Initializing Comptroller settings...");

        // Set Price Oracle
        // function _setPriceOracle(PriceOracle newOracle) public returns (uint)
        uint setOracleResult = peridotTrollerProxy._setPriceOracle(
            PriceOracle(ORACLE_ADDRESS)
        );
        if (setOracleResult != 0) {
            console.log("Error setting price oracle: %s", setOracleResult);
            revert("Failed to set price oracle");
        }
        console.log("  Price Oracle set to:", ORACLE_ADDRESS);

        // Set Close Factor
        // function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint)
        uint setCloseFactorResult = peridotTrollerProxy._setCloseFactor(
            closeFactorMantissa
        );
        if (setCloseFactorResult != 0) {
            console.log("Error setting close factor: %s", setCloseFactorResult);
            revert("Failed to set close factor");
        }
        console.log("  Close Factor set to:", closeFactorMantissa);

        // Set Liquidation Incentive
        // function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint)
        uint setLiqIncResult = peridotTrollerProxy._setLiquidationIncentive(
            liquidationIncentiveMantissa
        );
        if (setLiqIncResult != 0) {
            console.log(
                "Error setting liquidation incentive: %s",
                setLiqIncResult
            );
            revert("Failed to set liquidation incentive");
        }
        console.log(
            "  Liquidation Incentive set to:",
            liquidationIncentiveMantissa
        );

        // Example: Setting a default collateral factor for a market (usually done when adding markets)
        // address somePTokenAddress = address(0x...); // Replace with actual PToken address later
        // uint collateralFactorMantissa = 0.75e18; // 75%
        // comptrollerProxy._setCollateralFactor(somePTokenAddress, collateralFactorMantissa);
        // console.log("  (Example) Set Collateral Factor for Market %s to: %s", somePTokenAddress, collateralFactorMantissa);

        vm.stopBroadcast();

        console.log("==== Deployment Summary ====");
        console.log("Unitroller (Proxy):", address(unitroller));
        console.log(
            "PeridottrollerG7 (Implementation):",
            address(peridotTrollerImpl)
        );
        console.log(
            "PeridottrollerG7 Proxy (Use this address):",
            address(peridotTrollerProxy)
        );
        console.log("JumpRateModelV2:", address(interestRateModel));
        console.log("Comptroller Owner:", owner);

        // Store the oracle contract instance in a variable
        PriceOracle oracleInstance = peridotTrollerProxy.oracle(); // Changed type from address to PriceOracle
        console.log("Oracle Address Set:");
        console.log(address(oracleInstance)); // Cast to address for logging
    }
}
