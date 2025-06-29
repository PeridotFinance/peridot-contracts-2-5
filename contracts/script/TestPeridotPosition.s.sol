// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PErc20.sol";
import "../contracts/PToken.sol";
import "../contracts/PeridottrollerG7.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/EIP20Interface.sol";

contract TestPeridotPosition is Script {
    // BSC Testnet addresses from addresses.MD
    address constant PERIDOTTROLLER =
        0xe797A0001A3bC1B2760a24c3D7FDD172906bCCd6;
    address constant PPUSD_TOKEN = 0xEDdC65ECaF2e67c301a01fDc1da6805084f621D0;
    address constant PYUSD_UNDERLYING =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant MOCK_ORACLE = 0x82BF1C5516F6A91d4bF1E0aB62aF373dB049Df91;

    // Test user address (you can change this to any address you want to test)
    address constant TEST_USER = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;

    PeridottrollerG7 peridottroller;
    PErc20 pPUSD;
    EIP20Interface pyusd;
    PriceOracle oracle;

    function run() external {
        console.log("=== Peridot Position Test Script ===");
        console.log("Network: BSC Testnet");
        console.log("Test User:", TEST_USER);
        console.log("");

        // Initialize contracts
        peridottroller = PeridottrollerG7(PERIDOTTROLLER);
        pPUSD = PErc20(PPUSD_TOKEN);
        pyusd = EIP20Interface(PYUSD_UNDERLYING);
        oracle = PriceOracle(MOCK_ORACLE);

        // Run all tests
        test1_ConfirmSuppliedTokenBalance();
        test2_CheckCollateralFactor();
        test3_CheckUserInMarket();
        test4_VerifyPriceConfiguration();
        test5_EnsureCorrectPeridottroller();
        test6_ConfirmPeridottrollerConfiguration();
        test7_TestHypotheticalAccountLiquidity();

        console.log("=== Test Complete ===");
    }

    function test1_ConfirmSuppliedTokenBalance() internal view {
        console.log("Test 1: Confirm Supplied pToken Balance");
        console.log("----------------------------------------");

        // Get pToken balance
        uint pTokenBalance = pPUSD.balanceOf(TEST_USER);
        console.log("pPUSD Balance:", pTokenBalance);

        if (pTokenBalance > 0) {
            console.log("PASS: User has pPUSD tokens");

            // Get underlying balance using stored exchange rate
            uint exchangeRate = pPUSD.exchangeRateStored();
            console.log("Exchange Rate (stored):", exchangeRate);

            // Calculate underlying balance manually
            uint calculatedUnderlying = (pTokenBalance * exchangeRate) / 1e18;
            console.log("Calculated Underlying Balance:", calculatedUnderlying);

            // Get account snapshot (safer than balanceOfUnderlying)
            (
                uint error,
                uint pTokenBalance2,
                uint borrowBalance,
                uint exchangeRate2
            ) = pPUSD.getAccountSnapshot(TEST_USER);
            console.log("Account Snapshot - Error:", error);
            console.log("Account Snapshot - pToken Balance:", pTokenBalance2);
            console.log("Account Snapshot - Borrow Balance:", borrowBalance);
            console.log("Account Snapshot - Exchange Rate:", exchangeRate2);
        } else {
            console.log("INFO: User has no pPUSD tokens");
        }

        console.log("");
    }

    function test2_CheckCollateralFactor() internal view {
        console.log("Test 2: Check Collateral Factor");
        console.log("----------------------------------");

        (
            bool isListed,
            uint collateralFactorMantissa,
            bool isPeridot
        ) = peridottroller.markets(PPUSD_TOKEN);

        console.log("Is Listed:", isListed);
        console.log("Collateral Factor Mantissa:", collateralFactorMantissa);
        console.log("Is Peridot:", isPeridot);

        if (isListed) {
            uint collateralFactorPercent = (collateralFactorMantissa * 100) /
                1e18;
            console.log(
                "Collateral Factor Percentage:",
                collateralFactorPercent,
                "%"
            );

            if (collateralFactorMantissa > 0) {
                console.log("PASS: Market has collateral factor");
            } else {
                console.log("WARN: Collateral factor is 0% - no borrow power");
            }
        } else {
            console.log("FAIL: Market is not listed");
        }

        console.log("");
    }

    function test3_CheckUserInMarket() internal view {
        console.log("Test 3: Check User in Market");
        console.log("-------------------------------");

        PToken[] memory userAssets = peridottroller.getAssetsIn(TEST_USER);
        console.log("User is in", userAssets.length, "markets");

        bool inMarket = false;
        for (uint i = 0; i < userAssets.length; i++) {
            console.log("Asset", i, ":", address(userAssets[i]));
            if (address(userAssets[i]) == PPUSD_TOKEN) {
                inMarket = true;
            }
        }

        if (inMarket) {
            console.log("PASS: User is in pPUSD market");
        } else {
            console.log("INFO: User is NOT in pPUSD market");
        }

        // Check direct membership
        bool isMember = peridottroller.checkMembership(TEST_USER, pPUSD);
        console.log("Direct membership check:", isMember);

        console.log("");
    }

    function test4_VerifyPriceConfiguration() internal view {
        console.log("Test 4: Verify Price Configuration");
        console.log("-------------------------------------");

        // Check oracle address
        address oracleAddress = address(peridottroller.oracle());
        console.log("Peridottroller Oracle:", oracleAddress);
        console.log("Expected Oracle:", MOCK_ORACLE);

        if (oracleAddress == MOCK_ORACLE) {
            console.log("PASS: Oracle addresses match");
        } else {
            console.log("WARN: Oracle addresses don't match");
        }

        // Get price from oracle
        uint price = oracle.getUnderlyingPrice(pPUSD);
        console.log("PYUSD Price from Oracle:", price);

        if (price > 0) {
            console.log("PASS: Price is set");

            // Check underlying decimals
            uint8 underlyingDecimals = pyusd.decimals();
            console.log("PYUSD Decimals:", underlyingDecimals);

            // Expected price format for Compound: 1e(36 - underlyingDecimals)
            uint expectedPriceScale = 10 ** (36 - underlyingDecimals);
            console.log("Expected Price Scale:", expectedPriceScale);

            if (price >= expectedPriceScale / 1000) {
                console.log("PASS: Price seems reasonable");
            } else {
                console.log("WARN: Price might be too low");
            }
        } else {
            console.log("FAIL: Price is 0");
        }

        console.log("");
    }

    function test5_EnsureCorrectPeridottroller() internal view {
        console.log("Test 5: Ensure Correct Peridottroller");
        console.log("----------------------------------------");

        address pTokenPeridottroller = address(pPUSD.peridottroller());
        console.log("pPUSD Peridottroller:", pTokenPeridottroller);
        console.log("Test Peridottroller:", PERIDOTTROLLER);

        if (pTokenPeridottroller == PERIDOTTROLLER) {
            console.log("PASS: Peridottroller addresses match");
        } else {
            console.log("FAIL: Peridottroller mismatch");
        }

        console.log("");
    }

    function test6_ConfirmPeridottrollerConfiguration() internal view {
        console.log("Test 6: Confirm Peridottroller Configuration");
        console.log("-----------------------------------------------");

        // Check if oracle is set
        address oracleAddr = address(peridottroller.oracle());
        console.log("Oracle Address:", oracleAddr);

        if (oracleAddr != address(0)) {
            console.log("PASS: Oracle is set");
        } else {
            console.log("FAIL: No oracle set");
        }

        // Check if market is listed
        (bool isListed, , ) = peridottroller.markets(PPUSD_TOKEN);
        console.log("Market Listed:", isListed);

        if (isListed) {
            console.log("PASS: Market is listed");
        } else {
            console.log("FAIL: Market not listed");
        }

        // Get all markets
        PToken[] memory allMarkets = peridottroller.getAllMarkets();
        console.log("Total Markets:", allMarkets.length);

        bool foundMarket = false;
        for (uint i = 0; i < allMarkets.length; i++) {
            console.log("Market", i, ":", address(allMarkets[i]));
            if (address(allMarkets[i]) == PPUSD_TOKEN) {
                foundMarket = true;
            }
        }

        if (foundMarket) {
            console.log("PASS: pPUSD found in all markets");
        } else {
            console.log("WARN: pPUSD not found in all markets list");
        }

        console.log("");
    }

    function test7_TestHypotheticalAccountLiquidity() internal view {
        console.log("Test 7: Test Account Liquidity");
        console.log("-------------------------------");

        // Test current liquidity
        (uint error, uint liquidity, uint shortfall) = peridottroller
            .getAccountLiquidity(TEST_USER);

        console.log("Current Account Liquidity:");
        console.log("  Error Code:", error);
        console.log("  Liquidity:", liquidity);
        console.log("  Shortfall:", shortfall);

        if (error == 0) {
            if (liquidity > 0) {
                console.log("PASS: User has borrow power:", liquidity);
            } else if (shortfall > 0) {
                console.log("WARN: User has shortfall:", shortfall);
            } else {
                console.log("INFO: No liquidity, no shortfall");
            }
        } else {
            console.log("ERROR: getAccountLiquidity returned error:", error);
        }

        // Test hypothetical liquidity
        (uint hypoError, uint hypoLiquidity, uint hypoShortfall) = peridottroller
            .getHypotheticalAccountLiquidity(
                TEST_USER,
                PPUSD_TOKEN,
                0, // redeemTokens
                0 // borrowAmount
            );

        console.log("Hypothetical Account Liquidity (0 redeem, 0 borrow):");
        console.log("  Error Code:", hypoError);
        console.log("  Liquidity:", hypoLiquidity);
        console.log("  Shortfall:", hypoShortfall);

        if (
            hypoError == 0 &&
            hypoLiquidity == liquidity &&
            hypoShortfall == shortfall
        ) {
            console.log("PASS: Hypothetical matches current liquidity");
        } else {
            console.log("INFO: Hypothetical differs from current");
        }

        console.log("");
    }

    // Additional helper functions
    function checkUserBalances() external view {
        console.log("=== User Balance Check ===");
        console.log("User Address:", TEST_USER);

        // Check PYUSD balance
        uint pyusdBalance = pyusd.balanceOf(TEST_USER);
        console.log("PYUSD Balance:", pyusdBalance);

        // Check PYUSD allowance to pPUSD
        uint allowance = pyusd.allowance(TEST_USER, PPUSD_TOKEN);
        console.log("PYUSD Allowance to pPUSD:", allowance);

        // Check pPUSD balance
        uint pTokenBalance = pPUSD.balanceOf(TEST_USER);
        console.log("pPUSD Balance:", pTokenBalance);

        // Check borrow balance
        uint borrowBalance = pPUSD.borrowBalanceStored(TEST_USER);
        console.log("Borrow Balance:", borrowBalance);
    }
}
