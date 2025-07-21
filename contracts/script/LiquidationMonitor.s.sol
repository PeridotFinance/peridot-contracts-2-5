// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";
import "../contracts/PriceOracle.sol";

contract LiquidationMonitor is Script {
    address payable constant UNITROLLER =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant ORACLE = 0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;

    // Monitoring settings
    uint256 constant CHECK_INTERVAL = 60; // 60 seconds between checks
    uint256 constant MIN_PROFIT_USD = 1e6; // $1.00 minimum profit
    uint256 constant MAX_SLIPPAGE = 0.05e18; // 5% max slippage
    uint256 constant HEALTH_FACTOR_THRESHOLD = 1.03e18; // Liquidate when HF < 1.03

    struct MonitoringState {
        uint256 lastCheckTime;
        uint256 totalLiquidationsExecuted;
        uint256 totalProfitGenerated;
        uint256 totalGasUsed;
        uint256 successfulLiquidations;
        uint256 failedLiquidations;
    }

    struct QuickLiquidationCheck {
        address borrower;
        address pTokenBorrow;
        address pTokenCollateral;
        uint256 repayAmount;
        uint256 profitEstimate;
        bool shouldExecute;
    }

    MonitoringState monitoringState;
    Peridottroller unitroller;
    PriceOracle oracle;

    function run() external {
        console.log("Starting Liquidation Monitor...");
        console.log("Current block:", block.number);
        console.log("Current timestamp:", block.timestamp);

        unitroller = Peridottroller(UNITROLLER);
        oracle = PriceOracle(ORACLE);

        // Initialize monitoring state
        monitoringState.lastCheckTime = block.timestamp;

        vm.startBroadcast();

        // Run continuous monitoring loop
        runMonitoringLoop();

        vm.stopBroadcast();
    }

    function runMonitoringLoop() internal {
        console.log("Starting monitoring loop...");
        console.log("Check interval:", CHECK_INTERVAL, "seconds");
        console.log("Min profit threshold: $", MIN_PROFIT_USD / 1e6);

        // In a real implementation, this would be an infinite loop
        // For testing, we'll do a single comprehensive check

        uint256 startTime = block.timestamp;

        // Get all markets
        address[] memory markets = unitroller.getAllMarkets();
        console.log("Monitoring", markets.length, "markets");

        // Quick scan for liquidation opportunities
        QuickLiquidationCheck[] memory opportunities = quickScanForLiquidations(
            markets
        );

        console.log("Found", opportunities.length, "liquidation opportunities");

        // Execute high-value liquidations first
        executeHighValueLiquidations(opportunities);

        // Update monitoring statistics
        updateMonitoringStats();

        uint256 endTime = block.timestamp;
        console.log(
            "Monitoring cycle completed in",
            endTime - startTime,
            "seconds"
        );

        // Display monitoring summary
        displayMonitoringSummary();
    }

    function quickScanForLiquidations(
        address[] memory markets
    ) internal view returns (QuickLiquidationCheck[] memory) {
        // Fast scan using simplified logic for demo
        QuickLiquidationCheck[] memory tempChecks = new QuickLiquidationCheck[](
            100
        );
        uint256 checkCount = 0;

        // Sample accounts to check (in production, track from events)
        address[] memory sampleAccounts = getSampleAccounts();

        for (uint256 i = 0; i < sampleAccounts.length; i++) {
            address account = sampleAccounts[i];

            // Quick liquidity check
            (uint256 error, uint256 liquidity, uint256 shortfall) = unitroller
                .getAccountLiquidity(account);

            if (error == 0 && shortfall > MIN_PROFIT_USD) {
                console.log("Quick check - liquidatable account:", account);
                console.log("Shortfall:", shortfall);

                // Find best liquidation pair
                QuickLiquidationCheck
                    memory check = findQuickLiquidationOpportunity(
                        account,
                        markets,
                        shortfall
                    );

                if (check.shouldExecute) {
                    tempChecks[checkCount] = check;
                    checkCount++;
                }
            }
        }

        // Resize array
        QuickLiquidationCheck[] memory checks = new QuickLiquidationCheck[](
            checkCount
        );
        for (uint256 i = 0; i < checkCount; i++) {
            checks[i] = tempChecks[i];
        }

        return checks;
    }

    function getSampleAccounts() internal pure returns (address[] memory) {
        address[] memory accounts = new address[](8);
        accounts[0] = 0x1111111111111111111111111111111111111111;
        accounts[1] = 0x2222222222222222222222222222222222222222;
        accounts[2] = 0x3333333333333333333333333333333333333333;
        accounts[3] = 0x4444444444444444444444444444444444444444;
        accounts[4] = 0x5555555555555555555555555555555555555555;
        accounts[5] = 0x6666666666666666666666666666666666666666;
        accounts[6] = 0x7777777777777777777777777777777777777777;
        accounts[7] = 0x8888888888888888888888888888888888888888;

        return accounts;
    }

    function findQuickLiquidationOpportunity(
        address account,
        address[] memory markets,
        uint256 shortfall
    ) internal view returns (QuickLiquidationCheck memory) {
        uint256 bestProfit = 0;
        QuickLiquidationCheck memory bestCheck;

        // Check each borrow/collateral combination
        for (uint256 i = 0; i < markets.length; i++) {
            PToken pTokenBorrow = PToken(markets[i]);
            uint256 borrowBalance = pTokenBorrow.borrowBalanceStored(account);

            if (borrowBalance == 0) continue;

            for (uint256 j = 0; j < markets.length; j++) {
                if (i == j) continue;

                PToken pTokenCollateral = PToken(markets[j]);
                uint256 collateralBalance = pTokenCollateral.balanceOf(account);

                if (collateralBalance == 0) continue;

                // Quick profit calculation
                uint256 closeFactor = unitroller.closeFactorMantissa();
                uint256 maxRepay = (borrowBalance * closeFactor) / 1e18;

                uint256 borrowPrice = oracle.getUnderlyingPrice(markets[i]);
                uint256 collateralPrice = oracle.getUnderlyingPrice(markets[j]);

                if (borrowPrice == 0 || collateralPrice == 0) continue;

                uint256 repayValueUSD = (maxRepay * borrowPrice) / 1e18;
                uint256 seizeValueUSD = (repayValueUSD * 1.08e18) / 1e18; // 8% liquidation bonus
                uint256 profitUSD = seizeValueUSD > repayValueUSD
                    ? seizeValueUSD - repayValueUSD
                    : 0;

                if (profitUSD > bestProfit && profitUSD >= MIN_PROFIT_USD) {
                    bestProfit = profitUSD;
                    bestCheck = QuickLiquidationCheck({
                        borrower: account,
                        pTokenBorrow: markets[i],
                        pTokenCollateral: markets[j],
                        repayAmount: maxRepay,
                        profitEstimate: profitUSD,
                        shouldExecute: true
                    });
                }
            }
        }

        return bestCheck;
    }

    function executeHighValueLiquidations(
        QuickLiquidationCheck[] memory checks
    ) internal {
        console.log("Executing high-value liquidations...");

        // Sort by profit (highest first)
        for (uint256 i = 0; i < checks.length; i++) {
            for (uint256 j = i + 1; j < checks.length; j++) {
                if (checks[j].profitEstimate > checks[i].profitEstimate) {
                    QuickLiquidationCheck memory temp = checks[i];
                    checks[i] = checks[j];
                    checks[j] = temp;
                }
            }
        }

        uint256 executedCount = 0;
        uint256 maxExecutions = 5; // Limit to 5 liquidations per cycle

        for (
            uint256 i = 0;
            i < checks.length && executedCount < maxExecutions;
            i++
        ) {
            QuickLiquidationCheck memory check = checks[i];

            if (!check.shouldExecute) continue;

            console.log("Executing liquidation", executedCount + 1);
            console.log("  Profit estimate: $", check.profitEstimate / 1e6);
            console.log("  Borrower:", check.borrower);

            bool success = executeQuickLiquidation(check);

            if (success) {
                console.log("  Result: SUCCESS");
                monitoringState.successfulLiquidations++;
                monitoringState.totalProfitGenerated += check.profitEstimate;
                executedCount++;
            } else {
                console.log("  Result: FAILED");
                monitoringState.failedLiquidations++;
            }

            monitoringState.totalLiquidationsExecuted++;
        }

        console.log("Executed", executedCount, "liquidations this cycle");
    }

    function executeQuickLiquidation(
        QuickLiquidationCheck memory check
    ) internal returns (bool) {
        // Pre-execution checks
        if (!isLiquidationStillValid(check)) {
            console.log("    Liquidation no longer valid");
            return false;
        }

        // Execute the liquidation
        try
            PToken(check.pTokenBorrow).liquidateBorrow(
                check.borrower,
                check.repayAmount,
                PToken(check.pTokenCollateral)
            )
        returns (uint256 result) {
            return result == 0;
        } catch Error(string memory reason) {
            console.log("    Liquidation error:", reason);
            return false;
        } catch {
            console.log("    Liquidation failed: Unknown error");
            return false;
        }
    }

    function isLiquidationStillValid(
        QuickLiquidationCheck memory check
    ) internal view returns (bool) {
        // Re-check account liquidity
        (uint256 error, , uint256 shortfall) = unitroller.getAccountLiquidity(
            check.borrower
        );

        if (error != 0 || shortfall == 0) {
            return false;
        }

        // Check prices haven't moved too much
        uint256 borrowPrice = oracle.getUnderlyingPrice(check.pTokenBorrow);
        uint256 collateralPrice = oracle.getUnderlyingPrice(
            check.pTokenCollateral
        );

        if (borrowPrice == 0 || collateralPrice == 0) {
            return false;
        }

        // Re-calculate profit with current prices
        uint256 repayValueUSD = (check.repayAmount * borrowPrice) / 1e18;
        uint256 seizeValueUSD = (repayValueUSD * 1.08e18) / 1e18;
        uint256 currentProfit = seizeValueUSD > repayValueUSD
            ? seizeValueUSD - repayValueUSD
            : 0;

        return currentProfit >= MIN_PROFIT_USD;
    }

    function updateMonitoringStats() internal {
        monitoringState.lastCheckTime = block.timestamp;

        // Would update gas usage tracking in real implementation
        monitoringState.totalGasUsed += 100000; // Estimated gas per cycle
    }

    function displayMonitoringSummary() internal view {
        console.log("\n=== LIQUIDATION MONITOR SUMMARY ===");
        console.log(
            "Total liquidations executed:",
            monitoringState.totalLiquidationsExecuted
        );
        console.log(
            "Successful liquidations:",
            monitoringState.successfulLiquidations
        );
        console.log("Failed liquidations:", monitoringState.failedLiquidations);
        console.log(
            "Total profit generated: $",
            monitoringState.totalProfitGenerated / 1e6
        );
        console.log("Total gas used:", monitoringState.totalGasUsed);
        console.log("Last check time:", monitoringState.lastCheckTime);

        if (monitoringState.totalLiquidationsExecuted > 0) {
            uint256 successRate = (monitoringState.successfulLiquidations *
                100) / monitoringState.totalLiquidationsExecuted;
            console.log("Success rate:", successRate, "%");
        }

        console.log("====================================\n");
    }

    // Emergency functions
    function emergencyStop() external {
        console.log("EMERGENCY STOP TRIGGERED");
        // Would implement emergency stop logic
    }

    function getMonitoringStats()
        external
        view
        returns (MonitoringState memory)
    {
        return monitoringState;
    }
}
