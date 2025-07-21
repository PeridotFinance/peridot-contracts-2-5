// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/PeridottrollerG7.sol";
import "../contracts/PriceOracle.sol";

/**
 * @title SimpleAPYCheck
 * @dev Simple script to check basic APY data for Peridot Protocol
 *
 * Usage: forge script script/SimpleAPYCheck.s.sol:SimpleAPYCheck --rpc-url <your_rpc_url>
 */
contract SimpleAPYCheck is Script {
    // Monad Testnet addresses
    address constant PERIDOTTROLLER =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant ORACLE = 0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address payable constant PUSDC =
        payable(0xA72b43Bd60E5a9a13B99d0bDbEd36a9041269246);
    address payable constant PUSDT =
        payable(0xa568bD70068A940910d04117c36Ab1A0225FD140);

    uint256 constant BLOCKS_PER_YEAR = 63_072_000;
    uint256 constant MANTISSA = 1e18;

    function run() public view {
        console.log("=== SIMPLE APY CHECK ===");
        console.log("Monad Testnet - Blocks per year:", BLOCKS_PER_YEAR);
        console.log("");

        PeridottrollerG7 comptroller = PeridottrollerG7(PERIDOTTROLLER);
        PriceOracle oracle = PriceOracle(ORACLE);

        console.log("=== pUSDC ===");
        checkToken(PUSDC, "pUSDC", comptroller, oracle);

        console.log("");
        console.log("=== pUSDT ===");
        checkToken(PUSDT, "pUSDT", comptroller, oracle);
    }

    function checkToken(
        address payable pTokenAddress,
        string memory symbol,
        PeridottrollerG7 comptroller,
        PriceOracle oracle
    ) internal view {
        PErc20Delegator pToken = PErc20Delegator(pTokenAddress);

        console.log("Token:", symbol);
        console.log("Address:", pTokenAddress);

        // Basic data
        uint256 totalSupply = pToken.totalSupply();
        uint256 totalBorrows = pToken.totalBorrows();
        uint256 exchangeRate = pToken.exchangeRateStored();

        console.log("Total Supply (pTokens):", totalSupply);
        console.log("Total Borrows:", totalBorrows);
        console.log("Exchange Rate:", exchangeRate);

        // Calculate utilization
        uint256 utilization = 0;
        if (totalSupply > 0) {
            uint256 totalUnderlying = (totalSupply * exchangeRate) / MANTISSA;
            if (totalUnderlying > 0) {
                utilization = (totalBorrows * 10000) / totalUnderlying; // Basis points
            }
        }
        console.log("Utilization (bps):", utilization);

        // Get rates from interest rate model
        address rateModelAddress = address(pToken.interestRateModel());
        console.log("Interest Rate Model:", rateModelAddress);

        // Try to get PERIDOT speed
        uint256 peridotSpeed = comptroller.peridotSpeeds(pTokenAddress);
        console.log("PERIDOT Speed:", peridotSpeed, "per block");

        // Get price
        uint256 price = oracle.getUnderlyingPrice(PToken(pTokenAddress));
        console.log("Underlying Price:", price);

        // Reserve factor
        uint256 reserveFactor = pToken.reserveFactorMantissa();
        console.log("Reserve Factor:", (reserveFactor * 100) / MANTISSA, "%");
    }
}
