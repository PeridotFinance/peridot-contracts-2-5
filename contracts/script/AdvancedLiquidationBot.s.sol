// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/PToken.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/ERC20.sol";

contract AdvancedLiquidationBot is Script {
    // Protocol addresses on Monad Testnet
    address payable constant UNITROLLER =
        0xa41D586530BC7BC872095950aE03a780d5114445;
    address constant ORACLE = 0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0;
    address constant PERIDOT_TOKEN = 0x28fE679719e740D15FC60325416bB43eAc50cD15;

    // Known markets
    address constant pUSDC = 0xA72b43Bd60E5a9a13B99d0bDbEd36a9041269246;
    address constant pUSDT = 0xa568bD70068A940910d04117c36Ab1A0225FD140;

    // Liquidation settings
    uint256 constant MIN_LIQUIDATION_AMOUNT = 1e6; // Minimum 1 USDC worth (6 decimals)
    uint256 constant MAX_LIQUIDATION_AMOUNT = 10000e6; // Maximum 10,000 USDC worth
    uint256 constant MIN_PROFIT_USD = 0.5e6; // Minimum $0.50 profit to execute
    uint256 constant LIQUIDATION_INCENTIVE_MANTISSA = 1.08e18; // 8% liquidation bonus
    uint256 constant MAX_GAS_PRICE = 10 gwei; // Maximum gas price

    // Event signatures for tracking accounts
    bytes32 constant MINT_EVENT = keccak256("Mint(address,uint256,uint256)");
    bytes32 constant BORROW_EVENT =
        keccak256("Borrow(address,uint256,uint256,uint256)");
    bytes32 constant REDEEM_EVENT =
        keccak256("Redeem(address,uint256,uint256)");
    bytes32 constant REPAY_BORROW_EVENT =
        keccak256("RepayBorrow(address,address,uint256,uint256,uint256)");

    struct LiquidationTarget {
        address borrower;
        address pTokenBorrowed;
        address pTokenCollateral;
        uint256 maxRepayAmount;
        uint256 expectedSeizeTokens;
        uint256 profitEstimateUSD;
        uint256 healthFactor;
        bool isExecutable;
    }

    struct MarketState {
        address pToken;
        address underlying;
        uint256 collateralFactorMantissa;
        uint256 liquidationThresholdMantissa;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 priceUSD;
        uint256 exchangeRate;
        bool isListed;
    }

    struct AccountLiquidityInfo {
        uint256 totalCollateralValueUSD;
        uint256 totalBorrowValueUSD;
        uint256 availableLiquidity;
        uint256 shortfall;
        uint256 healthFactor;
        bool isLiquidatable;
    }

    Peridottroller unitroller;
    PriceOracle oracle;
    address[] trackedAccounts;
    mapping(address => bool) accountExists;

    function run() external {
        console.log("Starting Advanced Liquidation Bot...");
        console.log("Block number:", block.number);
        console.log("Timestamp:", block.timestamp);

        unitroller = Peridottroller(UNITROLLER);
        oracle = PriceOracle(ORACLE);

        vm.startBroadcast();

        // Get current market state
        address[] memory markets = unitroller.getAllMarkets();
        MarketState[] memory marketStates = getMarketStates(markets);

        console.log("Found", markets.length, "active markets");

        // Track accounts from recent events (last 1000 blocks)
        uint256 fromBlock = block.number > 1000 ? block.number - 1000 : 0;
        trackAccountsFromEvents(markets, fromBlock, block.number);

        console.log("Tracking", trackedAccounts.length, "accounts");

        // Find liquidation opportunities
        LiquidationTarget[] memory targets = findLiquidationTargets(
            trackedAccounts,
            marketStates
        );

        console.log("Found", targets.length, "potential liquidation targets");

        // Execute profitable liquidations
        executeLiquidations(targets, marketStates);

        vm.stopBroadcast();

        console.log("Advanced liquidation bot completed");
    }

    function getMarketStates(
        address[] memory markets
    ) internal view returns (MarketState[] memory) {
        MarketState[] memory states = new MarketState[](markets.length);

        for (uint256 i = 0; i < markets.length; i++) {
            address pTokenAddr = markets[i];
            PToken pToken = PToken(pTokenAddr);

            try pToken.underlying() returns (address underlying) {
                try unitroller.markets(pTokenAddr) returns (
                    bool isListed,
                    uint256 collateralFactorMantissa,
                    bool isPeridot
                ) {
                    states[i] = MarketState({
                        pToken: pTokenAddr,
                        underlying: underlying,
                        collateralFactorMantissa: collateralFactorMantissa,
                        liquidationThresholdMantissa: collateralFactorMantissa, // Same as collateral factor for simplicity
                        totalSupply: pToken.totalSupply(),
                        totalBorrow: pToken.totalBorrows(),
                        priceUSD: oracle.getUnderlyingPrice(pTokenAddr),
                        exchangeRate: pToken.exchangeRateStored(),
                        isListed: isListed
                    });
                } catch {
                    console.log("Failed to get market info for:", pTokenAddr);
                }
            } catch {
                // Handle pETH or other native tokens
                states[i] = MarketState({
                    pToken: pTokenAddr,
                    underlying: address(0), // ETH
                    collateralFactorMantissa: 0,
                    liquidationThresholdMantissa: 0,
                    totalSupply: 0,
                    totalBorrow: 0,
                    priceUSD: 0,
                    exchangeRate: 1e18,
                    isListed: false
                });
            }
        }

        return states;
    }

    function trackAccountsFromEvents(
        address[] memory markets,
        uint256 fromBlock,
        uint256 toBlock
    ) internal {
        console.log("Tracking accounts from block", fromBlock, "to", toBlock);

        // For demonstration, we'll add some common addresses that might have positions
        // In a real implementation, you would parse events from the blockchain

        address[] memory commonAccounts = new address[](10);
        commonAccounts[0] = 0x1111111111111111111111111111111111111111;
        commonAccounts[1] = 0x2222222222222222222222222222222222222222;
        commonAccounts[2] = 0x3333333333333333333333333333333333333333;
        commonAccounts[3] = 0x4444444444444444444444444444444444444444;
        commonAccounts[4] = 0x5555555555555555555555555555555555555555;
        commonAccounts[5] = 0x6666666666666666666666666666666666666666;
        commonAccounts[6] = 0x7777777777777777777777777777777777777777;
        commonAccounts[7] = 0x8888888888888888888888888888888888888888;
        commonAccounts[8] = 0x9999999999999999999999999999999999999999;
        commonAccounts[9] = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;

        for (uint256 i = 0; i < commonAccounts.length; i++) {
            addTrackedAccount(commonAccounts[i]);
        }
    }

    function addTrackedAccount(address account) internal {
        if (!accountExists[account]) {
            trackedAccounts.push(account);
            accountExists[account] = true;
        }
    }

    function findLiquidationTargets(
        address[] memory accounts,
        MarketState[] memory marketStates
    ) internal view returns (LiquidationTarget[] memory) {
        LiquidationTarget[] memory tempTargets = new LiquidationTarget[](
            accounts.length * marketStates.length
        );
        uint256 targetCount = 0;

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];

            // Get account liquidity info
            AccountLiquidityInfo memory liquidityInfo = getAccountLiquidityInfo(
                account,
                marketStates
            );

            if (liquidityInfo.isLiquidatable) {
                console.log("Found liquidatable account:", account);
                console.log("Health factor:", liquidityInfo.healthFactor);
                console.log("Shortfall USD:", liquidityInfo.shortfall);

                // Find best liquidation opportunity for this account
                LiquidationTarget memory bestTarget = findBestLiquidationTarget(
                    account,
                    marketStates,
                    liquidityInfo
                );

                if (bestTarget.isExecutable) {
                    tempTargets[targetCount] = bestTarget;
                    targetCount++;
                }
            }
        }

        // Resize to actual count
        LiquidationTarget[] memory targets = new LiquidationTarget[](
            targetCount
        );
        for (uint256 i = 0; i < targetCount; i++) {
            targets[i] = tempTargets[i];
        }

        // Sort by profitability (bubble sort for simplicity)
        for (uint256 i = 0; i < targets.length; i++) {
            for (uint256 j = i + 1; j < targets.length; j++) {
                if (
                    targets[j].profitEstimateUSD > targets[i].profitEstimateUSD
                ) {
                    LiquidationTarget memory temp = targets[i];
                    targets[i] = targets[j];
                    targets[j] = temp;
                }
            }
        }

        return targets;
    }

    function getAccountLiquidityInfo(
        address account,
        MarketState[] memory marketStates
    ) internal view returns (AccountLiquidityInfo memory) {
        uint256 totalCollateralValueUSD = 0;
        uint256 totalBorrowValueUSD = 0;

        for (uint256 i = 0; i < marketStates.length; i++) {
            if (!marketStates[i].isListed) continue;

            PToken pToken = PToken(marketStates[i].pToken);

            // Supply (collateral) value
            uint256 pTokenBalance = pToken.balanceOf(account);
            if (pTokenBalance > 0) {
                uint256 underlyingAmount = (pTokenBalance *
                    marketStates[i].exchangeRate) / 1e18;
                uint256 collateralValue = (underlyingAmount *
                    marketStates[i].priceUSD) / 1e18;
                uint256 weightedCollateralValue = (collateralValue *
                    marketStates[i].collateralFactorMantissa) / 1e18;
                totalCollateralValueUSD += weightedCollateralValue;
            }

            // Borrow value
            uint256 borrowBalance = pToken.borrowBalanceStored(account);
            if (borrowBalance > 0) {
                uint256 borrowValue = (borrowBalance *
                    marketStates[i].priceUSD) / 1e18;
                totalBorrowValueUSD += borrowValue;
            }
        }

        uint256 availableLiquidity = 0;
        uint256 shortfall = 0;

        if (totalCollateralValueUSD > totalBorrowValueUSD) {
            availableLiquidity = totalCollateralValueUSD - totalBorrowValueUSD;
        } else {
            shortfall = totalBorrowValueUSD - totalCollateralValueUSD;
        }

        uint256 healthFactor = totalBorrowValueUSD > 0
            ? (totalCollateralValueUSD * 1e18) / totalBorrowValueUSD
            : type(uint256).max;

        bool isLiquidatable = shortfall > 0;

        return
            AccountLiquidityInfo({
                totalCollateralValueUSD: totalCollateralValueUSD,
                totalBorrowValueUSD: totalBorrowValueUSD,
                availableLiquidity: availableLiquidity,
                shortfall: shortfall,
                healthFactor: healthFactor,
                isLiquidatable: isLiquidatable
            });
    }

    function findBestLiquidationTarget(
        address account,
        MarketState[] memory marketStates,
        AccountLiquidityInfo memory liquidityInfo
    ) internal view returns (LiquidationTarget memory) {
        LiquidationTarget memory bestTarget;
        uint256 bestProfit = 0;

        // Check all borrow/collateral combinations
        for (uint256 i = 0; i < marketStates.length; i++) {
            if (!marketStates[i].isListed) continue;

            PToken pTokenBorrowed = PToken(marketStates[i].pToken);
            uint256 borrowBalance = pTokenBorrowed.borrowBalanceStored(account);

            if (borrowBalance == 0) continue;

            for (uint256 j = 0; j < marketStates.length; j++) {
                if (i == j || !marketStates[j].isListed) continue;

                PToken pTokenCollateral = PToken(marketStates[j].pToken);
                uint256 collateralBalance = pTokenCollateral.balanceOf(account);

                if (collateralBalance == 0) continue;

                LiquidationTarget memory target = calculateLiquidationTarget(
                    account,
                    marketStates[i],
                    marketStates[j],
                    borrowBalance,
                    collateralBalance,
                    liquidityInfo.shortfall
                );

                if (
                    target.isExecutable && target.profitEstimateUSD > bestProfit
                ) {
                    bestProfit = target.profitEstimateUSD;
                    bestTarget = target;
                }
            }
        }

        return bestTarget;
    }

    function calculateLiquidationTarget(
        address borrower,
        MarketState memory borrowMarket,
        MarketState memory collateralMarket,
        uint256 borrowBalance,
        uint256 collateralBalance,
        uint256 shortfallUSD
    ) internal view returns (LiquidationTarget memory) {
        // Get close factor
        uint256 closeFactor = unitroller.closeFactorMantissa();

        // Calculate max repay amount (close factor % of total borrow)
        uint256 maxRepayAmount = (borrowBalance * closeFactor) / 1e18;

        // Don't repay more than needed to restore health
        uint256 shortfallInBorrowTokens = (shortfallUSD * 1e18) /
            borrowMarket.priceUSD;
        if (maxRepayAmount > shortfallInBorrowTokens) {
            maxRepayAmount = shortfallInBorrowTokens;
        }

        // Apply min/max limits
        if (maxRepayAmount < MIN_LIQUIDATION_AMOUNT) {
            return
                LiquidationTarget(
                    borrower,
                    borrowMarket.pToken,
                    collateralMarket.pToken,
                    0,
                    0,
                    0,
                    0,
                    false
                );
        }

        if (maxRepayAmount > MAX_LIQUIDATION_AMOUNT) {
            maxRepayAmount = MAX_LIQUIDATION_AMOUNT;
        }

        // Calculate seize amount with liquidation incentive
        uint256 repayValueUSD = (maxRepayAmount * borrowMarket.priceUSD) / 1e18;
        uint256 seizeValueUSD = (repayValueUSD *
            LIQUIDATION_INCENTIVE_MANTISSA) / 1e18;
        uint256 seizeTokens = (seizeValueUSD * 1e18) /
            collateralMarket.priceUSD;

        // Convert to pToken amount
        uint256 seizeAmount = (seizeTokens * 1e18) /
            collateralMarket.exchangeRate;

        // Check if enough collateral available
        if (seizeAmount > collateralBalance) {
            // Reduce proportionally
            maxRepayAmount = (maxRepayAmount * collateralBalance) / seizeAmount;
            seizeAmount = collateralBalance;
            seizeTokens = (seizeAmount * collateralMarket.exchangeRate) / 1e18;
            seizeValueUSD = (seizeTokens * collateralMarket.priceUSD) / 1e18;
        }

        // Calculate profit
        uint256 repayValueUSD_actual = (maxRepayAmount *
            borrowMarket.priceUSD) / 1e18;
        uint256 profitUSD = seizeValueUSD > repayValueUSD_actual
            ? seizeValueUSD - repayValueUSD_actual
            : 0;

        // Subtract gas costs
        uint256 estimatedGasCostUSD = 0.02e6; // $0.02 estimated gas cost
        if (profitUSD > estimatedGasCostUSD) {
            profitUSD -= estimatedGasCostUSD;
        } else {
            profitUSD = 0;
        }

        bool isExecutable = profitUSD >= MIN_PROFIT_USD && maxRepayAmount > 0;

        uint256 healthFactor = 0; // Would calculate based on post-liquidation state

        return
            LiquidationTarget({
                borrower: borrower,
                pTokenBorrowed: borrowMarket.pToken,
                pTokenCollateral: collateralMarket.pToken,
                maxRepayAmount: maxRepayAmount,
                expectedSeizeTokens: seizeAmount,
                profitEstimateUSD: profitUSD,
                healthFactor: healthFactor,
                isExecutable: isExecutable
            });
    }

    function executeLiquidations(
        LiquidationTarget[] memory targets,
        MarketState[] memory marketStates
    ) internal {
        console.log("Executing liquidations for", targets.length, "targets");

        for (uint256 i = 0; i < targets.length; i++) {
            LiquidationTarget memory target = targets[i];

            if (!target.isExecutable) continue;

            console.log("Executing liquidation", i + 1);
            console.log("  Borrower:", target.borrower);
            console.log("  Profit estimate USD:", target.profitEstimateUSD);
            console.log("  Repay amount:", target.maxRepayAmount);

            bool success = executeLiquidation(target);

            if (success) {
                console.log("  Status: SUCCESS");
            } else {
                console.log("  Status: FAILED");
            }

            // Add delay between liquidations to avoid MEV
            // vm.sleep(1000); // 1 second delay (if supported)
        }
    }

    function executeLiquidation(
        LiquidationTarget memory target
    ) internal returns (bool) {
        try
            PToken(target.pTokenBorrowed).liquidateBorrow(
                target.borrower,
                target.maxRepayAmount,
                PToken(target.pTokenCollateral)
            )
        returns (uint256 result) {
            if (result == 0) {
                console.log("  Liquidation successful");
                return true;
            } else {
                console.log("  Liquidation failed with error code:", result);
                return false;
            }
        } catch Error(string memory reason) {
            console.log("  Liquidation failed:", reason);
            return false;
        } catch {
            console.log("  Liquidation failed: Unknown error");
            return false;
        }
    }

    // Helper function to check if liquidation is still profitable
    function isLiquidationProfitable(
        LiquidationTarget memory target
    ) internal view returns (bool) {
        // Re-check profitability before execution
        // Gas price might have changed, market conditions might have shifted
        return target.profitEstimateUSD >= MIN_PROFIT_USD;
    }
}
