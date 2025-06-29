// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20.sol";
import "../contracts/PeridottrollerInterface.sol"; // Assuming Comptroller is already deployed
import "../contracts/InterestRateModel.sol"; // Assuming InterestRateModel is already deployed
import "../contracts/PErc20Delegate.sol";
import "../contracts/PErc20Delegator.sol";

/**
 * @title DeployPErc20Delegator
 * @dev Deploys a PErc20Delegator proxy and its PErc20Delegate implementation.
 * Usage: forge script script/DeployPErc20.s.sol:DeployPErc20 --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
 *
 * IMPORTANT: Update the constants below with your deployed addresses and desired parameters.
 */
contract DeployPErc20Delegator is Script {
    // --- CONFIGURATION ---
    // !!! IMPORTANT: Replace these placeholders !!!
    address constant UNDERLYING_ERC20_ADDRESS =
        0xa41D586530BC7BC872095950aE03a780d5114445; // Address of the underlying ERC20 (e.g., USDC)
    address constant COMPTROLLER_ADDRESS =
        0xe797A0001A3bC1B2760a24c3D7FDD172906bCCd6; // Address of the deployed Unitroller proxy
    address constant INTEREST_RATE_MODEL_ADDRESS =
        0xf66037a2b7aDA645f22523E0dDb461c9012125d1; // Address of the deployed InterestRateModel

    // PToken Parameters (Adjust as needed)
    // Initial exchange rate = (underlying / pToken) * 10^(18 + underlyingDecimals - pTokenDecimals)
    // Let's use the standard initial exchange rate = 2 * 10^(18 + underlying_decimals - ptoken_decimals)
    // Example USDC (6 dec), pUSDC (8 dec): 2 * 10^(18 + 6 - 8) = 2 * 10^16 = 2e16
    // A common starting point: initial exchange rate of 0.02 corresponds to 2e16 mantissa (assuming 18 decimals for mantissa)
    uint256 constant INITIAL_EXCHANGE_RATE_MANTISSA = 2e16; // Example: Initial exchange rate of 0.02, scaled by 1e18. Adjust based on decimals! Needs careful calculation.
    string constant PTOKEN_NAME = "Peridot PUSD"; // e.g., "Peridot USDC"
    string constant PTOKEN_SYMBOL = "pPUSD"; // e.g., "pUSDC"
    uint8 constant PTOKEN_DECIMALS = 8; // Standard PToken decimals

    address admin = msg.sender; // Admin/Owner address

    function setUp() public {
        /*if (
            UNDERLYING_ERC20_ADDRESS == address(0) ||
            COMPTROLLER_ADDRESS == address(0) ||
            INTEREST_RATE_MODEL_ADDRESS == address(0)
        ) {
            revert(
                "Placeholder addresses not set. Please update the constants in the script."
            );
        }
        admin = msg.sender; // Default admin to deployer*/
    }

    function run() public {
        console.log("Deploying PErc20 market...");
        console.log("  Underlying ERC20:", UNDERLYING_ERC20_ADDRESS);
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

        // 1. Deploy the PErc20Delegate (Implementation)
        PErc20Delegate delegate = new PErc20Delegate();
        console.log(
            "PErc20Delegate (Implementation) deployed at:",
            address(delegate)
        );

        // 2. Deploy the PErc20Delegator (Proxy)
        PErc20Delegator delegator = new PErc20Delegator(
            UNDERLYING_ERC20_ADDRESS,
            PeridottrollerInterface(COMPTROLLER_ADDRESS),
            InterestRateModel(INTEREST_RATE_MODEL_ADDRESS),
            INITIAL_EXCHANGE_RATE_MANTISSA,
            PTOKEN_NAME,
            PTOKEN_SYMBOL,
            PTOKEN_DECIMALS,
            payable(admin), // The final admin for the pToken proxy
            address(delegate), // The implementation address
            "" // Empty bytes for becomeImplementationData
        );

        vm.stopBroadcast();

        console.log("==== Deployment Complete ====");
        console.log(
            "PErc20Delegator (Proxy for",
            PTOKEN_SYMBOL,
            ") deployed at:",
            address(delegator)
        );
        console.log("  -> Implementation (PErc20Delegate):", address(delegate));

        // IMPORTANT NEXT STEP: You need to add this market to the Comptroller
        // using comptrollerProxy._supportMarket(address(pToken));
        console.log(
            "!!! IMPORTANT: Remember to add this market to the Comptroller using _supportMarket !!!"
        );
    }
}
