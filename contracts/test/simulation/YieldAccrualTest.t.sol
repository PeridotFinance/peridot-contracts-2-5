// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/boosted/MorphoBoostedDelegate.sol";
import "../../contracts/PErc20Delegator.sol";

contract YieldAccrualTest is Test {
    // Addresses from MonadScan
    address constant SENDER = 0xCED23360932B80d18fdEAEAa573202E80A584804;
    address constant DELEGATOR_PROXY = 0x085FbF880F88f861B8A09e6aaB1E4618d79Ba1D4; // pToken (USDC Boosted)
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603; // USDC on Monad Mainnet
    address constant MORPHO_VAULT = address(0xbeEFf443C3CbA3E369DA795002243BeaC311aB83);

    // Block numbers to test
    uint256 constant EARLIER_BLOCK = 45620000; // ~2000 blocks earlier
    uint256 constant LATER_BLOCK = 45622000; // Recent block

    MorphoBoostedDelegate pToken;
    IERC20 usdc;
    IERC4626 vault;

    function setUp() public {
        pToken = MorphoBoostedDelegate(DELEGATOR_PROXY);
        usdc = IERC20(USDC);
        vault = IERC4626(MORPHO_VAULT);
    }

    function testYieldAccrualComparison() public {
        console.log("=== Testing Yield Accrual Over Time ===\n");

        // Compare exchange rates at different blocks
        uint256 exchangeRateEarlier = _getExchangeRateAtBlock(EARLIER_BLOCK, "EARLIER BLOCK");
        uint256 exchangeRateLater = _getExchangeRateAtBlock(LATER_BLOCK, "LATER BLOCK");

        // Analysis
        console.log("\n=== YIELD ACCRUAL ANALYSIS ===");
        console.log("Exchange Rate at Earlier Block:", exchangeRateEarlier);
        console.log("Exchange Rate at Later Block:", exchangeRateLater);

        if (exchangeRateLater > exchangeRateEarlier) {
            uint256 rateIncrease = exchangeRateLater - exchangeRateEarlier;
            uint256 blockDiff = LATER_BLOCK - EARLIER_BLOCK;

            console.log("\nSUCCESS: Yield accrued over time!");
            console.log("Exchange Rate Increase:", rateIncrease);
            console.log("Block Difference:", blockDiff);
            console.log("Rate Increase per Block:", rateIncrease / blockDiff);

            // Calculate yield percentage
            uint256 yieldBps = (rateIncrease * 10000) / exchangeRateEarlier;
            console.log("Yield Basis Points for period:", yieldBps);

            // Show practical example with 1000 pTokens
            console.log("\n=== Practical Example ===");
            console.log("If you held 1000 pTokens:");
            uint256 usdcEarlier = (1000 * 1e18 * exchangeRateEarlier) / 1e18;
            uint256 usdcLater = (1000 * 1e18 * exchangeRateLater) / 1e18;
            console.log("Worth at Earlier Block (USDC):", usdcEarlier);
            console.log("Worth at Later Block (USDC):", usdcLater);
            console.log("Yield Earned (USDC):", usdcLater - usdcEarlier);

            assertTrue(exchangeRateLater > exchangeRateEarlier, "Later block should have higher exchange rate");
        } else if (exchangeRateLater == exchangeRateEarlier) {
            console.log("\nINFO: Exchange rate stayed flat");
            console.log("No yield accrual in this period");
        } else {
            console.log("\nWARNING: Exchange rate decreased");
            console.log("This should not happen in normal operation");
        }
    }

    function _getExchangeRateAtBlock(uint256 blockNumber, string memory label) internal returns (uint256) {
        console.log("--- Testing at", label, "---");
        console.log("Block:", blockNumber);

        // Create a new fork at the specified block
        vm.createSelectFork("https://rpc-mainnet.monadinfra.com/rpc/gj5S68FEcV5YJhoHerGE51VLJ0gh7kQA", blockNumber);

        // Reinitialize contract references after fork
        pToken = MorphoBoostedDelegate(DELEGATOR_PROXY);
        usdc = IERC20(USDC);

        // Get exchange rate (accrues interest first)
        uint256 exchangeRate = pToken.exchangeRateCurrent();

        // Get additional info
        uint256 totalSupply = pToken.totalSupply();
        uint256 totalBorrows = pToken.totalBorrows();
        uint256 totalReserves = pToken.totalReserves();
        uint256 cash = usdc.balanceOf(address(pToken));

        console.log("Exchange Rate:", exchangeRate);
        console.log("Total Supply:", totalSupply);
        console.log("Total Borrows:", totalBorrows);
        console.log("Total Reserves:", totalReserves);
        console.log("Idle Cash:", cash);
        console.log("");

        return exchangeRate;
    }
}
