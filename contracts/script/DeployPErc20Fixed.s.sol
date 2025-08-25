// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/PErc20Delegate.sol";
import "../contracts/PErc20Delegator.sol";

/**
 * @title DeployPErc20Fixed
 * @dev Fixed deployment script that properly handles admin assignment and sets reserve factor
 */
contract DeployPErc20Fixed is Script {
    // --- CONFIGURATION ---
    address constant UNDERLYING_ERC20_ADDRESS =
        0xaEef2f6B429Cb59C9B2D7bB2141ADa993E8571c3;
    address constant COMPTROLLER_ADDRESS =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0x2d271dEb2596d78aaa2551695Ebfa9Cd440713aC;

    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e26;
    string constant PTOKEN_NAME = "Peridot gMON";
    string constant PTOKEN_SYMBOL = "pgMON";
    uint8 constant PTOKEN_DECIMALS = 8;

    // Reserve factor (15% = 0.15 * 1e18)
    uint256 constant RESERVE_FACTOR = 0.08 * 1e18;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying PErc20 with Fixed Admin ===");
        console.log("Deployer address:", deployer);
        console.log("Underlying ERC20:", UNDERLYING_ERC20_ADDRESS);
        console.log("Comptroller:", COMPTROLLER_ADDRESS);
        console.log("Interest Rate Model:", INTEREST_RATE_MODEL_ADDRESS);
        console.log("Reserve Factor:", RESERVE_FACTOR);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the PErc20Delegate (Implementation)
        PErc20Delegate delegate = new PErc20Delegate();
        console.log("PErc20Delegate deployed at:", address(delegate));

        // 2. Deploy the PErc20Delegator (Proxy) with deployer as admin
        PErc20Delegator delegator = new PErc20Delegator(
            UNDERLYING_ERC20_ADDRESS,
            PeridottrollerInterface(COMPTROLLER_ADDRESS),
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS),
            INITIAL_EXCHANGE_RATE_MANTISSA,
            PTOKEN_NAME,
            PTOKEN_SYMBOL,
            PTOKEN_DECIMALS,
            payable(deployer), // Explicitly set deployer as admin
            address(delegate),
            ""
        );

        console.log("PErc20Delegator deployed at:", address(delegator));

        // 3. Verify admin is correct
        address currentAdmin = delegator.admin();
        console.log("Current admin:", currentAdmin);

        if (currentAdmin != deployer) {
            console.log("WARNING: Admin mismatch detected!");
            console.log("Expected:", deployer);
            console.log("Actual:", currentAdmin);

            // Try to recover admin rights
            if (delegator.pendingAdmin() == deployer) {
                console.log("Attempting to accept admin role...");
                uint256 result = delegator._acceptAdmin();
                if (result == 0) {
                    console.log("Successfully accepted admin role");
                } else {
                    console.log(
                        " Failed to accept admin role, error code:",
                        result
                    );
                }
            } else {
                console.log(" Cannot recover admin rights automatically");
                console.log("Manual intervention required");
            }
        } else {
            console.log(" Admin is correctly set");
        }

        // 4. Set reserve factor
        console.log("Setting reserve factor to 15%...");
        uint256 reserveResult = delegator._setReserveFactor(RESERVE_FACTOR);
        if (reserveResult == 0) {
            console.log(" Successfully set reserve factor to 15%");
        } else {
            console.log(
                " Failed to set reserve factor, error code:",
                reserveResult
            );
        }

        // 5. Verify reserve factor
        uint256 currentReserveFactor = delegator.reserveFactorMantissa();
        console.log("Current reserve factor:", currentReserveFactor);
        console.log("Expected reserve factor:", RESERVE_FACTOR);

        if (currentReserveFactor == RESERVE_FACTOR) {
            console.log(" Reserve factor correctly set");
        } else {
            console.log(" Reserve factor mismatch");
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("PErc20Delegator (Proxy):", address(delegator));
        console.log("PErc20Delegate (Implementation):", address(delegate));
        console.log("Admin:", delegator.admin());
        console.log("Reserve Factor:", delegator.reserveFactorMantissa());
        console.log(
            "\n IMPORTANT: Remember to add this market to the Comptroller using _supportMarket"
        );
    }
}
