// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeployDualInvestmentUpgradeable
 * @notice Deployment script for Dual Investment system with protocol integration
 *
 * USAGE:
 * 1. Update the addresses in the CONFIGURATION section below
 * 2. Run: forge script script/DeployDualInvestmentUpgradeable.s.sol --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY
 *
 * CONTRACTS DEPLOYED:
 * - ERC1155DualPosition: Position token management
 * - VaultExecutor: Vault operations
 * - SettlementEngine: Position settlement
 * - CompoundBorrowRouter: Borrowing integration
 * - RiskGuard: Risk management
 * - DualInvestmentManagerUpgradeable: Main manager contract
 */

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Core contracts
import "../contracts/DualInvestment/ERC1155DualPosition.sol";
import "../contracts/DualInvestment/VaultExecutor.sol";
import "../contracts/DualInvestment/SettlementEngine.sol";
import "../contracts/DualInvestment/CompoundBorrowRouter.sol";
import "../contracts/DualInvestment/RiskGuard.sol";
import "../contracts/DualInvestment/DualInvestmentManagerUpgradeable.sol";

contract DeployDualInvestmentUpgradeable is Script {
    // ========================================
    // CONFIGURATION - UPDATE THESE ADDRESSES
    // ========================================

    // Core protocol addresses - UPDATE THESE
    address public constant PRICE_ORACLE =
        0xBfEaDDA58d0583f33309AdE83F35A680824E397f; // SimplePriceOracle (BSC testnet)
    address public constant PERIDOTTROLLER =
        0x2e6aeB2AA9B1fC76aCD2E9E5EfeC2bF39C3a9094; // Peridottroller address
    address public constant PROTOCOL_ACCOUNT =
        0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9; // Protocol treasury account - UPDATE THIS

    // Protocol integration - UPDATE THESE
    address public constant PROTOCOL_TREASURY =
        0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9; // Protocol treasury for fees - UPDATE THIS
    address public constant PROTOCOL_TOKEN =
        0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed; // Governance/reward token (optional)

    // Supported cToken addresses - UPDATE THESE
    address public constant CTOKEN_PWBTC =
        0x08eD77C8A3A48c03fE38A4AdEC2F4204Cf4Fbf1F; // pWBTC address - UPDATE THIS
    address public constant CTOKEN_PUSDC =
        0xF0a6303cA0A99d9235979b317E3a78083162a88B; // pUSDC address - UPDATE THIS
    address public constant CTOKEN_PUSDT =
        0xC4FE7BD6b9EdD67bF2ba5daa317D7cd80E1913bb; // pUSDT address - UPDATE THIS

    // Risk parameters (shortened for manual testing; adjust for production)
    uint256 public constant SETTLEMENT_WINDOW = 60 minutes;
    uint256 public constant MIN_HEALTH_FACTOR = 1.25e18; // 125%
    uint256 public constant MAX_LTV = 0.75e18; // 75%
    // Liquidation handled by Peridottroller
    uint256 public constant MAX_POSITION_SIZE_RATIO = 0.25e18; // 50%

    // Manager risk params (shorter expiry for manual tests)
    uint256 public constant MAX_POSITION_SIZE = 1000000e18;
    uint256 public constant MIN_POSITION_SIZE = 1e8;
    uint256 public constant MAX_EXPIRY = 30 days;
    uint256 public constant MIN_EXPIRY = 2 minutes;

    // Protocol integration parameters
    uint256 public constant PROTOCOL_FEE_RATE = 50; // 0.5% in basis points
    // Auto-compounding removed

    struct DeploymentAddresses {
        address positionToken;
        address vaultExecutor;
        address settlementEngine;
        address borrowRouter;
        address riskGuard;
        address manager;
    }

    function run() external returns (DeploymentAddresses memory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Dual Investment System ===");
        console.log("Deployer address:", deployer);
        console.log("Price Oracle:", PRICE_ORACLE);
        console.log("Peridottroller:", PERIDOTTROLLER);
        console.log("Protocol Account:", PROTOCOL_ACCOUNT);
        console.log("Protocol Treasury:", PROTOCOL_TREASURY);

        // Validate configuration
        require(PRICE_ORACLE != address(0), "PRICE_ORACLE not configured");
        require(PERIDOTTROLLER != address(0), "PERIDOTTROLLER not configured");
        require(
            PROTOCOL_ACCOUNT != address(0),
            "PROTOCOL_ACCOUNT not configured"
        );
        require(
            PROTOCOL_TREASURY != address(0),
            "PROTOCOL_TREASURY not configured"
        );

        vm.startBroadcast(deployerPrivateKey);

        DeploymentAddresses memory addresses = _deployContracts();
        _setupAuthorizations(addresses);
        _configureRiskParameters(addresses);
        _transferComponentOwnerships(addresses);
        _addSupportedCTokens(addresses);
        _printDeploymentSummary(addresses);

        vm.stopBroadcast();
        return addresses;
    }

    function _deployContracts()
        internal
        returns (DeploymentAddresses memory addresses)
    {
        console.log("\n=== Deploying Core Contracts ===");

        console.log("1. Deploying ERC1155DualPosition...");
        addresses.positionToken = address(new ERC1155DualPosition());
        console.log("   Deployed at:", addresses.positionToken);

        console.log("2. Deploying VaultExecutor...");
        addresses.vaultExecutor = address(new VaultExecutor(PROTOCOL_ACCOUNT));
        console.log("   Deployed at:", addresses.vaultExecutor);

        console.log("3. Deploying SettlementEngine...");
        addresses.settlementEngine = address(
            new SettlementEngine(
                addresses.positionToken,
                addresses.vaultExecutor,
                PRICE_ORACLE
            )
        );
        console.log("   Deployed at:", addresses.settlementEngine);

        console.log("4. Deploying CompoundBorrowRouter...");
        addresses.borrowRouter = address(
            new CompoundBorrowRouter(PERIDOTTROLLER, PRICE_ORACLE)
        );
        console.log("   Deployed at:", addresses.borrowRouter);

        console.log("5. Deploying RiskGuard...");
        addresses.riskGuard = address(
            new RiskGuard(PERIDOTTROLLER, PRICE_ORACLE)
        );
        console.log("   Deployed at:", addresses.riskGuard);

        console.log("6. Deploying DualInvestmentManager...");
        addresses.manager = address(new DualInvestmentManagerUpgradeable());
        console.log("   Deployed at:", addresses.manager);

        console.log("7. Initializing DualInvestmentManager...");
        DualInvestmentManagerUpgradeable(addresses.manager).initialize(
            addresses.positionToken,
            addresses.vaultExecutor,
            addresses.settlementEngine,
            addresses.borrowRouter,
            addresses.riskGuard,
            PERIDOTTROLLER,
            PROTOCOL_TREASURY,
            PROTOCOL_TOKEN
        );
        console.log("   Initialized successfully");
    }

    function _setupAuthorizations(
        DeploymentAddresses memory addresses
    ) internal {
        console.log("\n=== Setting up Authorizations ===");

        // Position token authorizations
        ERC1155DualPosition(addresses.positionToken).setAuthorizedMinter(
            addresses.manager,
            true
        );
        ERC1155DualPosition(addresses.positionToken).setAuthorizedMinter(
            addresses.settlementEngine,
            true
        );
        console.log(
            "Authorized DualInvestmentManager and SettlementEngine to mint/burn position tokens"
        );

        // Vault executor authorizations
        VaultExecutor(addresses.vaultExecutor).setAuthorizedManager(
            addresses.manager,
            true
        );
        VaultExecutor(addresses.vaultExecutor).setAuthorizedManager(
            addresses.settlementEngine,
            true
        );
        console.log(
            "Authorized DualInvestmentManager and SettlementEngine to use VaultExecutor"
        );

        // Borrow router authorizations
        CompoundBorrowRouter(addresses.borrowRouter).setAuthorizedDestination(
            addresses.vaultExecutor,
            true
        );
        console.log("Authorized VaultExecutor as borrow destination");

        // Ownership transfers moved to a later step after configuration
    }

    function _configureRiskParameters(
        DeploymentAddresses memory addresses
    ) internal {
        console.log("\n=== Configuring Risk Parameters ===");

        DualInvestmentManagerUpgradeable manager = DualInvestmentManagerUpgradeable(
                addresses.manager
            );

        // Configure manager risk parameters (short minExpiry for manual testing)
        manager.setRiskParameters(
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE,
            MAX_EXPIRY,
            MIN_EXPIRY
        );
        console.log("Manager risk parameters configured");

        // Configure settlement window
        SettlementEngine(addresses.settlementEngine).setSettlementWindow(
            SETTLEMENT_WINDOW
        );
        console.log(
            "Settlement window configured:",
            SETTLEMENT_WINDOW / 3600,
            "hours"
        );

        // Configure borrow router parameters
        CompoundBorrowRouter(addresses.borrowRouter).setMinHealthFactor(
            MIN_HEALTH_FACTOR
        );
        CompoundBorrowRouter(addresses.borrowRouter).setMaxLTV(MAX_LTV);
        console.log("Borrow router parameters configured");

        // Configure risk guard parameters
        RiskGuard(addresses.riskGuard).setMaxPositionSizeRatio(
            MAX_POSITION_SIZE_RATIO
        );
        console.log("Risk guard parameters configured");

        // Set protocol fee to 0 for v1
        manager.updateProtocolConfig(PROTOCOL_TREASURY, 0, PROTOCOL_TOKEN);
        console.log("Protocol fee set to 0 bps");

        console.log("Protocol integration configured");
    }

    function _transferComponentOwnerships(
        DeploymentAddresses memory addresses
    ) internal {
        console.log("\n=== Transferring Component Ownerships ===");
        // Transfer ownership to manager for risk management after configuration
        CompoundBorrowRouter(addresses.borrowRouter).transferOwnership(
            addresses.manager
        );
        RiskGuard(addresses.riskGuard).transferOwnership(addresses.manager);
        console.log(
            "Transferred ownership of RiskGuard and BorrowRouter to manager"
        );
    }

    function _addSupportedCTokens(
        DeploymentAddresses memory addresses
    ) internal {
        console.log("\n=== Adding Supported cTokens ===");

        DualInvestmentManagerUpgradeable manager = DualInvestmentManagerUpgradeable(
                addresses.manager
            );

        address[] memory cTokens = new address[](3);
        string[] memory names = new string[](3);
        uint256 count = 0;

        if (CTOKEN_PWBTC != address(0)) {
            cTokens[count] = CTOKEN_PWBTC;
            names[count] = "pWBTC";
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

        if (count > 0) {
            for (uint256 i = 0; i < count; i++) {
                manager.setSupportedCToken(cTokens[i], true);
                manager.setMarketIntegration(cTokens[i], true);
                manager.setMarketUtilizationBonus(cTokens[i], 100); // 1% bonus
                console.log(
                    "Added",
                    names[i],
                    "support and integration:",
                    cTokens[i]
                );
            }
        } else {
            console.log("No cTokens configured (all addresses are zero)");
            console.log(
                "Update cToken addresses in script and redeploy, or add support manually"
            );
        }
    }

    function _printDeploymentSummary(
        DeploymentAddresses memory addresses
    ) internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Core Contracts:");
        console.log("  ERC1155DualPosition:        ", addresses.positionToken);
        console.log("  VaultExecutor:              ", addresses.vaultExecutor);
        console.log(
            "  SettlementEngine:           ",
            addresses.settlementEngine
        );
        console.log("  CompoundBorrowRouter:       ", addresses.borrowRouter);
        console.log("  RiskGuard:                  ", addresses.riskGuard);
        console.log("  DualInvestmentManager:      ", addresses.manager);
        console.log("");
        console.log("Configuration:");
        console.log("  Protocol Treasury:          ", PROTOCOL_TREASURY);
        console.log("  Protocol Token:             ", PROTOCOL_TOKEN);
        console.log("  Fee Rate:                   ", PROTOCOL_FEE_RATE, "bps");
        console.log("");
        console.log("Dual Investment System deployed successfully!");
        console.log("Main contract address:        ", addresses.manager);
    }
}
