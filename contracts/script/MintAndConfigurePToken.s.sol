// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../contracts/PErc20Delegator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MintAndConfigurePToken
 * @notice Script to approve, mint pTokens, and set reserve factor.
 *
 * Usage:
 *   forge script script/MintAndConfigurePToken.s.sol \
 *     --rpc-url $MONAD_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract MintAndConfigurePToken is Script {
    // ========== CONFIGURATION - EDIT THESE ==========

    // pToken address to interact with
    address constant PTOKEN_ADDRESS =
        0x085FbF880F88f861B8A09e6aaB1E4618d79Ba1D4;

    // Amount of underlying to mint (e.g., 1e6 = 1 USDC for 6 decimals)
    uint256 constant MINT_AMOUNT = 1e6;

    // Reserve factor (e.g., 0.10e18 = 10%)
    uint256 constant RESERVE_FACTOR = 0.10e18;

    // Set to true to skip minting
    bool constant SKIP_MINT = false;

    // Set to true to skip reserve factor setting
    bool constant SKIP_RESERVE = false;

    // ================================================

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        PErc20Delegator pToken = PErc20Delegator(payable(PTOKEN_ADDRESS));
        address underlying = pToken.underlying();

        console2.log("=== MintAndConfigurePToken ===");
        console2.log("Deployer:", deployer);
        console2.log("pToken:", PTOKEN_ADDRESS);
        console2.log("Underlying:", underlying);
        console2.log("Mint Amount:", MINT_AMOUNT);
        console2.log("Reserve Factor:", RESERVE_FACTOR);

        vm.startBroadcast(deployerKey);

        // 1. Approve and mint pTokens
        if (!SKIP_MINT && MINT_AMOUNT > 0) {
            uint256 balance = IERC20(underlying).balanceOf(deployer);
            console2.log("Underlying balance:", balance);
            require(balance >= MINT_AMOUNT, "Insufficient underlying balance");

            // Approve
            IERC20(underlying).approve(PTOKEN_ADDRESS, MINT_AMOUNT);
            console2.log("Approved underlying to pToken");

            // Mint pTokens
            uint256 mintResult = pToken.mint(MINT_AMOUNT);
            require(mintResult == 0, "Mint failed");
            console2.log("Minted pTokens successfully");

            // Check pToken balance
            uint256 pTokenBalance = pToken.balanceOf(deployer);
            console2.log("pToken balance:", pTokenBalance);
        }

        // 2. Set reserve factor (must be admin)
        if (!SKIP_RESERVE) {
            uint256 reserveResult = pToken._setReserveFactor(RESERVE_FACTOR);
            if (reserveResult == 0) {
                console2.log("Reserve factor set successfully");
            } else {
                console2.log(
                    "Failed to set reserve factor, error code:",
                    reserveResult
                );
            }
        }

        vm.stopBroadcast();

        // Final status
        console2.log("");
        console2.log("=== Final Status ===");
        console2.log("pToken balance:", pToken.balanceOf(deployer));
        console2.log("Exchange rate:", pToken.exchangeRateStored());
        console2.log("Total supply:", pToken.totalSupply());
        console2.log("Total borrows:", pToken.totalBorrows());
        console2.log("Reserve factor:", pToken.reserveFactorMantissa());
    }
}
