// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PEther.sol";
import "../contracts/PeridottrollerInterface.sol"; // Assuming Comptroller is already deployed
import "../contracts/InterestRateModel.sol"; // Assuming InterestRateModel is already deployed

/**
 * @title DeployPEther
 * @dev Deploys the PEther contract.
 * Usage: forge script script/DeployPEther.s.sol:DeployPEther --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 *
 * IMPORTANT: Update the constants below with your deployed addresses and desired parameters.
 */
contract DeployPEther is Script {
    // --- CONFIGURATION ---
    // !!! IMPORTANT: Replace these placeholders !!!
    address constant COMPTROLLER_ADDRESS =
        0xfB3f8837B1Ad7249C1B253898b3aa7FaB22E68aD; // Address of the deployed Unitroller proxy
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0xcf26c1EcB6482a9A626d986A8E3c87fb68f2F8f3; // Address of the deployed InterestRateModel

    // PToken Parameters (Adjust as needed)
    // Similar calculation as PErc20, but underlying decimals is always 18 for native currency
    // Initial exchange rate = 2 * 10^(18 + 18 - pTokenDecimals)
    // Example pETH (8 dec): 2 * 10^(18 + 18 - 8) = 2 * 10^28 = 2e28
    // Use the standard initial exchange rate of 0.02, scaled by 1e18.
    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e16; // Example: Initial exchange rate of 0.02. Adjust if needed.
    string constant PTOKEN_NAME = "Peridot Ether"; // Example name
    string constant PTOKEN_SYMBOL = "pETH"; // Example symbol
    uint8 constant PTOKEN_DECIMALS = 8; // Standard PToken decimals

    address admin; // Admin/Owner address

    function setUp() public {
        if (
            COMPTROLLER_ADDRESS == address(0) ||
            INTEREST_RATE_MODEL_ADDRESS == address(0)
        ) {
            revert(
                "Placeholder addresses not set. Please update the constants in the script."
            );
        }
        admin = msg.sender; // Default admin to deployer
    }

    function run() public {
        console.log("Deploying PEther market...");
        console.log("  Comptroller:", COMPTROLLER_ADDRESS);
        console.log("  Interest Rate Model:", INTEREST_RATE_MODEL_ADDRESS);
        console.log("  PToken Name:", PTOKEN_NAME);
        console.log("  PToken Symbol:", PTOKEN_SYMBOL);
        console.log("  PToken Decimals:", PTOKEN_DECIMALS);
        console.log(
            "  Initial Exchange Rate Mantissa:",
            INITIAL_EXCHANGE_RATE_MANTISSA
        );
        console.log("  Admin:", admin);

        vm.startBroadcast();

        PEther pEther = new PEther(
            PeridottrollerInterface(COMPTROLLER_ADDRESS),
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS),
            INITIAL_EXCHANGE_RATE_MANTISSA,
            PTOKEN_NAME,
            PTOKEN_SYMBOL,
            PTOKEN_DECIMALS,
            payable(admin) // Set deployer as admin (payable constructor)
        );

        vm.stopBroadcast();

        console.log("==== Deployment Complete ====");
        console.log(
            "PEther (",
            PTOKEN_SYMBOL,
            ") deployed at:",
            address(pEther)
        );

        // IMPORTANT NEXT STEP: You need to add this market to the Comptroller
        // using comptrollerProxy._supportMarket(address(pEther));
        console.log(
            "!!! IMPORTANT: Remember to add this market to the Comptroller using _supportMarket !!!"
        );
    }
}
