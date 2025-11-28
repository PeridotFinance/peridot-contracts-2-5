// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/PErc20Delegate.sol";
import "../contracts/PErc20Delegator.sol";

// PToken Parameters (Adjust as needed)
// Initial exchange rate = (underlying / pToken) * 10^(18 + underlyingDecimals - pTokenDecimals)
// Example USDC (6 dec), pUSDC (8 dec): 2 * 10^(18 + 6 - 8) = 2 * 10^16 = 2e16
// A common starting point: initial exchange rate of 0.02 corresponds to 2e16 mantissa (assuming 18 decimals for mantissa)
// Underlying decimals	Constant to use 6=2e14, 8=2e16, 18=2e26

/**
 * @title DeployPErc20Fixed
 * @dev Fixed deployment script that properly handles admin assignment and sets reserve factor
 */
contract DeployPErc20Fixed is Script {
    // --- CONFIGURATION ---
    address constant UNDERLYING_ERC20_ADDRESS =
        0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081;
    address constant COMPTROLLER_ADDRESS =
        0x6D208789f0a978aF789A3C8Ba515749598940716;
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0x1FB287E1c4F7B4c6b511f4d190523814593Ad84e;

    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e26;
    string constant PTOKEN_NAME = "Peridot gMON";
    string constant PTOKEN_SYMBOL = "pgMON"; // Underlying decimals	Constant to use 6=2e14, 8=2e16, 18=2e26
    uint8 constant PTOKEN_DECIMALS = 8;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATEMAIN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying PErc20 with Fixed Admin ===");
        console.log("Deployer address:", deployer);
        console.log("Underlying ERC20:", UNDERLYING_ERC20_ADDRESS);
        console.log("Comptroller:", COMPTROLLER_ADDRESS);
        console.log("Interest Rate Model:", INTEREST_RATE_MODEL_ADDRESS);

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

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("PErc20Delegator (Proxy):", address(delegator));
        console.log("PErc20Delegate (Implementation):", address(delegate));
        console.log("Admin:", delegator.admin());
        console.log(
            "\n IMPORTANT: Remember to add this market to the Comptroller using _supportMarket"
        );
    }
}
