// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/PTokenInterfaces.sol";

contract LiquidationBot is Script {
    // Protocol addresses on Monad Testnet
    address payable constant UNITROLLER =
        payable(0xa41D586530BC7BC872095950aE03a780d5114445);
    address constant ORACLE = 0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant PERIDOT_TOKEN = 0x28fE679719e740D15FC60325416bB43eAc50cD15;

    // Known markets
    address constant pUSDC = 0xA72b43Bd60E5a9a13B99d0bDbEd36a9041269246;
    address constant pUSDT = 0xa568bD70068A940910d04117c36Ab1A0225FD140;

    // Liquidation settings
    uint256 constant MIN_LIQUIDATION_AMOUNT = 1e18; // Minimum 1 USD worth
    uint256 constant MAX_LIQUIDATION_AMOUNT = 1000e18; // Maximum 1000 USD worth
    uint256 constant LIQUIDATION_INCENTIVE = 1.08e18; // 8% liquidation bonus

    struct LiquidationOpportunity {
        address borrower;
        address pTokenBorrowed;
        address pTokenCollateral;
        uint256 liquidationAmount;
        uint256 expectedSeizeAmount;
        uint256 profitEstimate;
    }

    struct AccountSnapshot {
        address account;
        uint256 totalSupplyValueUSD;
        uint256 totalBorrowValueUSD;
        uint256 healthFactor;
        bool isLiquidatable;
    }

    Peridottroller unitroller;
    PriceOracle oracle;

    function run() external {
        console.log("Starting Liquidation Bot...");
        console.log("Unitroller:", UNITROLLER);
        console.log("Oracle:", ORACLE);

        unitroller = Peridottroller(UNITROLLER);
        oracle = PriceOracle(ORACLE);

        vm.startBroadcast();

        // Get all markets
        PToken[] memory markets = unitroller.getAllMarkets();
        console.log("Found", markets.length, "markets");

        // Get all accounts that have interacted with the protocol
        address[] memory accounts = getAllActiveAccounts(markets);
        console.log(
            "Checking",
            accounts.length,
            "accounts for liquidation opportunities"
        );

        // Check each account for liquidation opportunities
        LiquidationOpportunity[]
            memory opportunities = findLiquidationOpportunities(
                accounts,
                markets
            );

        // Execute profitable liquidations
        executeLiquidations(opportunities);

        vm.stopBroadcast();

        console.log("Liquidation bot completed");
    }

    function getAllActiveAccounts(
        PToken[] memory markets
    ) internal returns (address[] memory) {
        string[] memory lines = vm.readFileLines("accounts.txt");
        address[] memory accounts = new address[](lines.length);
        for (uint i = 0; i < lines.length; i++) {
            accounts[i] = vm.parseAddress(lines[i]);
        }
        return accounts;
    }

    function findLiquidationOpportunities(
        address[] memory accounts,
        PToken[] memory markets
    ) internal view returns (LiquidationOpportunity[] memory) {
        LiquidationOpportunity[]
            memory tempOpportunities = new LiquidationOpportunity[](
                accounts.length * markets.length
            );
        uint256 opportunityCount = 0;

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            // Check if account is liquidatable
            (uint256 error, uint256 liquidity, uint256 shortfall) = unitroller
                .getAccountLiquidity(account);

            if (error == 0 && shortfall > 0) {
                console.log("Found liquidatable account:", account);
                console.log("Shortfall:", shortfall);

                // Find best liquidation opportunity for this account
                LiquidationOpportunity
                    memory bestOpportunity = findBestLiquidationForAccount(
                        account,
                        markets,
                        shortfall
                    );

                if (bestOpportunity.liquidationAmount > 0) {
                    tempOpportunities[opportunityCount] = bestOpportunity;
                    opportunityCount++;
                }
            }
        }

        // Resize array to actual count
        LiquidationOpportunity[]
            memory opportunities = new LiquidationOpportunity[](
                opportunityCount
            );
        for (uint256 i = 0; i < opportunityCount; i++) {
            opportunities[i] = tempOpportunities[i];
        }

        return opportunities;
    }

    function findBestLiquidationForAccount(
        address account,
        PToken[] memory markets,
        uint256 shortfall
    ) internal view returns (LiquidationOpportunity memory) {
        LiquidationOpportunity memory bestOpportunity;
        uint256 bestProfit = 0;

        // Check each market for borrowings
        for (uint256 i = 0; i < markets.length; i++) {
            PToken pTokenBorrowed = markets[i];

            // Get borrowed amount
            uint256 borrowBalance = pTokenBorrowed.borrowBalanceStored(account);
            if (borrowBalance == 0) continue;

            // Check each market for collateral
            for (uint256 j = 0; j < markets.length; j++) {
                if (i == j) continue; // Can't liquidate same asset

                PToken pTokenCollateral = markets[j];

                // Get collateral balance
                uint256 collateralBalance = pTokenCollateral.balanceOf(account);
                if (collateralBalance == 0) continue;

                // Calculate liquidation opportunity
                LiquidationOpportunity
                    memory opportunity = calculateLiquidationOpportunity(
                        account,
                        pTokenBorrowed,
                        pTokenCollateral,
                        borrowBalance,
                        collateralBalance,
                        shortfall
                    );

                if (opportunity.profitEstimate > bestProfit) {
                    bestProfit = opportunity.profitEstimate;
                    bestOpportunity = opportunity;
                }
            }
        }

        return bestOpportunity;
    }

    function calculateLiquidationOpportunity(
        address borrower,
        PToken pTokenBorrowed,
        PToken pTokenCollateral,
        uint256 borrowBalance,
        uint256 collateralBalance,
        uint256 shortfall
    ) internal view returns (LiquidationOpportunity memory) {
        // Get the close factor (maximum % of borrow that can be liquidated)
        uint256 closeFactor = unitroller.closeFactorMantissa();

        // Calculate maximum liquidation amount (50% of borrow by default)
        uint256 maxLiquidationAmount = (borrowBalance * closeFactor) / 1e18;

        // Don't liquidate more than the shortfall converted to borrow token units
        uint256 borrowPrice = oracle.getUnderlyingPrice(pTokenBorrowed);
        uint256 shortfallInBorrowTokens = (shortfall * 1e18) / borrowPrice;

        if (maxLiquidationAmount > shortfallInBorrowTokens) {
            maxLiquidationAmount = shortfallInBorrowTokens;
        }

        // Apply min/max limits
        if (maxLiquidationAmount < MIN_LIQUIDATION_AMOUNT) {
            return
                LiquidationOpportunity(
                    borrower,
                    address(pTokenBorrowed),
                    address(pTokenCollateral),
                    0,
                    0,
                    0
                );
        }

        if (maxLiquidationAmount > MAX_LIQUIDATION_AMOUNT) {
            maxLiquidationAmount = MAX_LIQUIDATION_AMOUNT;
        }

        // Calculate expected seize amount with liquidation incentive
        uint256 collateralPrice = oracle.getUnderlyingPrice(pTokenCollateral);

        uint256 borrowValueUSD = (maxLiquidationAmount * borrowPrice) / 1e18;
        uint256 seizeValueUSD = (borrowValueUSD * LIQUIDATION_INCENTIVE) / 1e18;
        uint256 expectedSeizeAmount = (seizeValueUSD * 1e18) / collateralPrice;

        // Check if we have enough collateral to seize
        uint256 maxSeizable = pTokenCollateral.balanceOf(borrower);

        if (expectedSeizeAmount > maxSeizable) {
            // Reduce liquidation amount proportionally
            maxLiquidationAmount =
                (maxLiquidationAmount * maxSeizable) /
                expectedSeizeAmount;
            expectedSeizeAmount = maxSeizable;
        }

        // Estimate profit (seize value - repay value - gas costs)
        uint256 repayValueUSD = (maxLiquidationAmount * borrowPrice) / 1e18;
        uint256 seizeValueUSD_actual = (expectedSeizeAmount * collateralPrice) /
            1e18;
        uint256 profitEstimate = seizeValueUSD_actual > repayValueUSD
            ? seizeValueUSD_actual - repayValueUSD
            : 0;

        // Subtract estimated gas costs (rough estimate)
        uint256 gasCostUSD = 0.01e18; // $0.01 in gas
        if (profitEstimate > gasCostUSD) {
            profitEstimate -= gasCostUSD;
        } else {
            profitEstimate = 0;
        }

        return
            LiquidationOpportunity({
                borrower: borrower,
                pTokenBorrowed: address(pTokenBorrowed),
                pTokenCollateral: address(pTokenCollateral),
                liquidationAmount: maxLiquidationAmount,
                expectedSeizeAmount: expectedSeizeAmount,
                profitEstimate: profitEstimate
            });
    }

    function executeLiquidations(
        LiquidationOpportunity[] memory opportunities
    ) internal {
        console.log("Found", opportunities.length, "liquidation opportunities");

        for (uint256 i = 0; i < opportunities.length; i++) {
            LiquidationOpportunity memory opp = opportunities[i];

            if (opp.liquidationAmount == 0) continue;

            console.log("Executing liquidation:");
            console.log("  Borrower:", opp.borrower);
            console.log("  Borrowed token:", opp.pTokenBorrowed);
            console.log("  Collateral token:", opp.pTokenCollateral);
            console.log("  Liquidation amount:", opp.liquidationAmount);
            console.log("  Expected profit:", opp.profitEstimate);

            // Execute the liquidation
            bool success = executeLiquidation(opp);

            if (success) {
                console.log("  Status: SUCCESS");
            } else {
                console.log("  Status: FAILED");
            }
        }
    }

    function executeLiquidation(
        LiquidationOpportunity memory opp
    ) internal returns (bool) {
        try
            PErc20Interface(opp.pTokenBorrowed).liquidateBorrow(
                opp.borrower,
                opp.liquidationAmount,
                PTokenInterface(opp.pTokenCollateral)
            )
        returns (uint256 result) {
            return result == 0;
        } catch {
            console.log("  Error: Liquidation transaction failed");
            return false;
        }
    }

    function getAccountSnapshot(
        address account,
        PToken[] memory markets
    ) internal view returns (AccountSnapshot memory) {
        uint256 totalSupplyUSD = 0;
        uint256 totalBorrowUSD = 0;

        for (uint256 i = 0; i < markets.length; i++) {
            PToken pToken = markets[i];
            uint256 price = oracle.getUnderlyingPrice(pToken);

            // Supply value
            uint256 supply = pToken.balanceOf(account);
            uint256 exchangeRate = pToken.exchangeRateStored();
            uint256 underlyingSupply = (supply * exchangeRate) / 1e18;
            totalSupplyUSD += (underlyingSupply * price) / 1e18;

            // Borrow value
            uint256 borrow = pToken.borrowBalanceStored(account);
            totalBorrowUSD += (borrow * price) / 1e18;
        }

        (uint256 error, uint256 liquidity, uint256 shortfall) = unitroller
            .getAccountLiquidity(account);
        bool isLiquidatable = (error == 0 && shortfall > 0);

        uint256 healthFactor = totalBorrowUSD > 0
            ? (totalSupplyUSD * 1e18) / totalBorrowUSD
            : type(uint256).max;

        return
            AccountSnapshot({
                account: account,
                totalSupplyValueUSD: totalSupplyUSD,
                totalBorrowValueUSD: totalBorrowUSD,
                healthFactor: healthFactor,
                isLiquidatable: isLiquidatable
            });
    }
}
