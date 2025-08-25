// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeployDualInvestment
 * @notice Deployment script for Dual Investment Phase 2 system
 *
 * USAGE:
 * 1. Update the addresses in the CONFIGURATION section below
 * 2. Run: forge script script/DeployDualInvestment.s.sol --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY
 *
 * CONTRACTS DEPLOYED:
 * - Phase 1: ERC1155DualPosition, VaultExecutor, SettlementEngine
 * - Phase 2: CompoundBorrowRouter, RiskGuard, DualInvestmentManager
 *
 * POST-DEPLOYMENT:
 * - Use ConfigureDualInvestment to add additional cToken support
 * - Use TestDualInvestmentPhase2 to test functionality
 */

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Phase 1 Dual Investment contracts
import "../contracts/DualInvestment/ERC1155DualPosition.sol";
import "../contracts/DualInvestment/VaultExecutor.sol";
import "../contracts/DualInvestment/SettlementEngine.sol";

// Phase 2 Dual Investment contracts
import "../contracts/DualInvestment/CompoundBorrowRouter.sol";
import "../contracts/DualInvestment/RiskGuard.sol";
import "../contracts/DualInvestment/DualInvestmentManager.sol";

contract DeployDualInvestment is Script {
    // ========================================
    // CONFIGURATION - UPDATE THESE ADDRESSES
    // ========================================

    // Core protocol addresses - UPDATE THESE
    address public constant PRICE_ORACLE = address(0); // SimplePriceOracle address - UPDATE THIS
    address public constant PERIDOTTROLLER = address(0); // Peridottroller address - UPDATE THIS
    address public constant PROTOCOL_ACCOUNT = address(0); // Protocol treasury account - UPDATE THIS

    // Supported cToken addresses - UPDATE THESE
    address public constant CTOKEN_PETH = address(0); // pETH address - UPDATE THIS
    address public constant CTOKEN_PUSDC = address(0); // pUSDC address - UPDATE THIS
    address public constant CTOKEN_PUSDT = address(0); // pUSDT address - UPDATE THIS
    address public constant CTOKEN_PWBTC = address(0); // pWBTC address - UPDATE THIS
    address public constant CTOKEN_PDAI = address(0); // pDAI address - UPDATE THIS

    // Risk parameters
    uint256 public constant SETTLEMENT_WINDOW = 60 minutes; // shorter for manual testing
    uint256 public constant MAX_POSITION_SIZE = 1000000e18; // 1M tokens
    uint256 public constant MIN_POSITION_SIZE = 1e18; // 1 token
    uint256 public constant MAX_EXPIRY = 30 days;
    uint256 public constant MIN_EXPIRY = 2 minutes; // shorter for manual testing

    // Phase 2 risk parameters
    uint256 public constant MIN_HEALTH_FACTOR = 1.25e18; // 125%
    uint256 public constant MAX_LTV = 0.75e18; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 1.1e18; // 110%
    uint256 public constant MAX_POSITION_SIZE_RATIO = 0.5e18; // 50%

    function run() external {
        vm.startBroadcast();

        // Validate configuration addresses
        require(PRICE_ORACLE != address(0), "PRICE_ORACLE not configured");
        require(PERIDOTTROLLER != address(0), "PERIDOTTROLLER not configured");
        require(
            PROTOCOL_ACCOUNT != address(0),
            "PROTOCOL_ACCOUNT not configured"
        );

        console.log("=== Deploying Dual Investment Phase 2 ===");
        console.log("Price Oracle:", PRICE_ORACLE);
        console.log("Peridottroller:", PERIDOTTROLLER);
        console.log("Protocol Account:", PROTOCOL_ACCOUNT);

        // 1. Deploy ERC1155DualPosition
        console.log("\n1. Deploying ERC1155DualPosition...");
        ERC1155DualPosition positionToken = new ERC1155DualPosition();
        console.log("ERC1155DualPosition deployed at:", address(positionToken));

        // 2. Deploy VaultExecutor
        console.log("\n2. Deploying VaultExecutor...");
        VaultExecutor vaultExecutor = new VaultExecutor(PROTOCOL_ACCOUNT);
        console.log("VaultExecutor deployed at:", address(vaultExecutor));

        // 3. Deploy SettlementEngine
        console.log("\n3. Deploying SettlementEngine...");
        SettlementEngine settlementEngine = new SettlementEngine(
            address(positionToken),
            address(vaultExecutor),
            PRICE_ORACLE
        );
        console.log("SettlementEngine deployed at:", address(settlementEngine));

        // 4. Deploy Phase 2 contracts
        console.log("\n4. Deploying CompoundBorrowRouter...");
        CompoundBorrowRouter borrowRouter = new CompoundBorrowRouter(
            PERIDOTTROLLER,
            PRICE_ORACLE
        );
        console.log("CompoundBorrowRouter deployed at:", address(borrowRouter));

        console.log("\n5. Deploying RiskGuard...");
        RiskGuard riskGuard = new RiskGuard(PERIDOTTROLLER, PRICE_ORACLE);
        console.log("RiskGuard deployed at:", address(riskGuard));

        console.log("\n6. Deploying DualInvestmentManager (Phase 2)...");
        DualInvestmentManager manager = new DualInvestmentManager(
            address(positionToken),
            address(vaultExecutor),
            address(settlementEngine),
            address(borrowRouter),
            address(riskGuard),
            PERIDOTTROLLER
        );
        console.log("DualInvestmentManager deployed at:", address(manager));

        // 7. Set up authorizations
        console.log("\n7. Setting up authorizations...");

        // Position token authorizations
        positionToken.setAuthorizedMinter(address(manager), true);
        positionToken.setAuthorizedMinter(address(settlementEngine), true);
        console.log(
            "Authorized DualInvestmentManager and SettlementEngine to mint/burn position tokens"
        );

        // Vault executor authorizations
        vaultExecutor.setAuthorizedManager(address(manager), true);
        vaultExecutor.setAuthorizedManager(address(settlementEngine), true);
        console.log(
            "Authorized DualInvestmentManager and SettlementEngine to use VaultExecutor"
        );

        // Borrow router authorizations
        borrowRouter.setAuthorizedDestination(address(vaultExecutor), true);
        console.log("Authorized VaultExecutor as borrow destination");

        // 8. Configure risk parameters
        console.log("\n8. Configuring risk parameters...");
        manager.setRiskParameters(
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE,
            MAX_EXPIRY,
            MIN_EXPIRY
        );
        console.log("Manager risk parameters configured");

        // Configure settlement window
        settlementEngine.setSettlementWindow(SETTLEMENT_WINDOW);
        console.log("Settlement window configured");

        // Configure borrow router parameters
        borrowRouter.setMinHealthFactor(MIN_HEALTH_FACTOR);
        borrowRouter.setMaxLTV(MAX_LTV);
        console.log("Borrow router parameters configured");

        // Configure risk guard parameters
        // Liquidation handled by Peridottroller; set position ratio only
        riskGuard.setMaxPositionSizeRatio(MAX_POSITION_SIZE_RATIO);
        console.log("Risk guard parameters configured");

        // Set protocol fee to 0 for v1-like behavior
        // Non-upgradeable manager has no protocol fee feature; skip

        // 9. Add supported cTokens (if environment variables are provided)
        _addSupportedCTokens(manager);

        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Phase 1 Contracts:");
        console.log("  ERC1155DualPosition:   ", address(positionToken));
        console.log("  VaultExecutor:         ", address(vaultExecutor));
        console.log("  SettlementEngine:      ", address(settlementEngine));
        console.log("");
        console.log("Phase 2 Contracts:");
        console.log("  CompoundBorrowRouter:  ", address(borrowRouter));
        console.log("  RiskGuard:             ", address(riskGuard));
        console.log("  DualInvestmentManager: ", address(manager));
        console.log("");
        console.log("Configuration:");
        console.log("  Protocol Account:      ", PROTOCOL_ACCOUNT);
        console.log("  Settlement Window:     ", SETTLEMENT_WINDOW, "seconds");
        console.log("  Min Health Factor:     ", MIN_HEALTH_FACTOR / 1e16, "%");
        console.log("  Max LTV:               ", MAX_LTV / 1e16, "%");
        console.log("");
        console.log(
            "Phase 2 Dual Investment deployment completed successfully!"
        );

        vm.stopBroadcast();
    }

    function _addSupportedCTokens(DualInvestmentManager manager) internal {
        // Add supported cTokens from hardcoded addresses
        address[] memory cTokens = new address[](5);
        string[] memory names = new string[](5);
        uint256 count = 0;

        // Add cTokens if they are configured (not zero address)
        if (CTOKEN_PETH != address(0)) {
            cTokens[count] = CTOKEN_PETH;
            names[count] = "pETH";
            count++;
        }

        if (CTOKEN_PUSDC != address(0)) {
            cTokens[count] = CTOKEN_PUSDC;
            names[count] = "pUSDC";
            count++;
        }

        if (CTOKEN_PUSDT != address(0)) {
            cTokens[count] = CTOKEN_PUSDT;
            names[count] = "pUSDT";
            count++;
        }

        if (CTOKEN_PWBTC != address(0)) {
            cTokens[count] = CTOKEN_PWBTC;
            names[count] = "pWBTC";
            count++;
        }

        if (CTOKEN_PDAI != address(0)) {
            cTokens[count] = CTOKEN_PDAI;
            names[count] = "pDAI";
            count++;
        }

        if (count > 0) {
            console.log("\n9. Adding supported cTokens...");
            for (uint256 i = 0; i < count; i++) {
                manager.setSupportedCToken(cTokens[i], true);
                console.log("Added", names[i], "support:", cTokens[i]);
            }
        } else {
            console.log("\n9. No cTokens configured (all addresses are zero)");
            console.log(
                "Update cToken addresses in script and redeploy, or add support manually"
            );
        }
    }
}

// Additional script for configuration after deployment
contract ConfigureDualInvestment is Script {
    // UPDATE THESE ADDRESSES FOR POST-DEPLOYMENT CONFIGURATION
    address public constant DEPLOYED_MANAGER = address(0); // DualInvestmentManager address - UPDATE THIS
    address public constant ADDITIONAL_CTOKEN = address(0); // Additional cToken to support - UPDATE THIS

    function run() external {
        vm.startBroadcast();

        require(
            DEPLOYED_MANAGER != address(0),
            "DEPLOYED_MANAGER not configured"
        );

        console.log("Configuring DualInvestment at:", DEPLOYED_MANAGER);

        // Add additional cToken support if configured
        if (ADDITIONAL_CTOKEN != address(0)) {
            DualInvestmentManager(DEPLOYED_MANAGER).setSupportedCToken(
                ADDITIONAL_CTOKEN,
                true
            );
            console.log("Added additional cToken support:", ADDITIONAL_CTOKEN);
        }

        vm.stopBroadcast();
    }
}

// Script for testing Phase 2 dual investment with local testnet
contract TestDualInvestmentPhase2 is Script {
    // UPDATE THESE ADDRESSES FOR TESTING
    address public constant DEPLOYED_MANAGER = address(0); // DualInvestmentManager address - UPDATE THIS
    address public constant DEPLOYED_BORROW_ROUTER = address(0); // CompoundBorrowRouter address - UPDATE THIS
    address public constant DEPLOYED_RISK_GUARD = address(0); // RiskGuard address - UPDATE THIS
    address public constant TEST_USER = address(0); // Test user address - UPDATE THIS
    address public constant TEST_CTOKEN_IN = address(0); // pETH for testing - UPDATE THIS
    address public constant TEST_CTOKEN_OUT = address(0); // pUSDC for testing - UPDATE THIS

    function run() external {
        vm.startBroadcast();

        require(
            DEPLOYED_MANAGER != address(0),
            "DEPLOYED_MANAGER not configured"
        );

        console.log("Testing Phase 2 dual investment...");
        console.log("Manager:", DEPLOYED_MANAGER);
        console.log("Test user:", TEST_USER);

        // Test parameters
        uint256 amount = 1e18; // 1 ETH worth of cTokens
        bool useCollateral = true;

        console.log("\n--- Testing Position Entry Capability ---");

        // Test collateral path
        console.log("Testing collateral path...");
        (
            bool canEnterCollateral,
            string memory reasonCollateral
        ) = DualInvestmentManager(DEPLOYED_MANAGER).canEnterPosition(
                TEST_USER,
                TEST_CTOKEN_IN,
                amount,
                true
            );

        console.log("Can enter with collateral:", canEnterCollateral);
        if (!canEnterCollateral) {
            console.log("Reason:", reasonCollateral);
        }

        // Test borrow path
        console.log("Testing borrow path...");
        (
            bool canEnterBorrow,
            string memory reasonBorrow
        ) = DualInvestmentManager(DEPLOYED_MANAGER).canEnterPosition(
                TEST_USER,
                TEST_CTOKEN_IN,
                amount,
                false
            );

        console.log("Can enter with borrowing:", canEnterBorrow);
        if (!canEnterBorrow) {
            console.log("Reason:", reasonBorrow);
        }

        // Test borrow router functionality
        if (DEPLOYED_BORROW_ROUTER != address(0)) {
            console.log("\n--- Testing Borrow Router ---");
            (bool canBorrow, string memory borrowReason) = CompoundBorrowRouter(
                DEPLOYED_BORROW_ROUTER
            ).canUserBorrow(TEST_USER, TEST_CTOKEN_IN, amount);

            console.log("Can user borrow:", canBorrow);
            if (!canBorrow) {
                console.log("Borrow reason:", borrowReason);
            }
        }

        // Test risk guard functionality
        if (DEPLOYED_RISK_GUARD != address(0)) {
            console.log("\n--- Testing Risk Guard ---");
            uint256 positionValueUSD = 2400e18; // Assume $2400 position
            (bool riskAllowed, string memory riskReason) = RiskGuard(
                DEPLOYED_RISK_GUARD
            ).checkPositionEntry(
                    TEST_USER,
                    TEST_CTOKEN_IN,
                    positionValueUSD,
                    useCollateral
                );

            console.log("Risk guard allows position:", riskAllowed);
            if (!riskAllowed) {
                console.log("Risk reason:", riskReason);
            }

            // Get user health factor
            uint256 healthFactor = RiskGuard(DEPLOYED_RISK_GUARD)
                .getUserHealthFactor(TEST_USER);
            console.log("User health factor:", healthFactor);
        }

        console.log("\nPhase 2 testing completed");
        vm.stopBroadcast();
    }
}
