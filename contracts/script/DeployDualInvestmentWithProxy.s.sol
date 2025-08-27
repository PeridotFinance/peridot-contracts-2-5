// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DeployDualInvestmentWithProxy
 * @notice Deployment script for Dual Investment system using TransparentUpgradeableProxy for the manager.
 *
 * USAGE:
 * forge script script/DeployDualInvestmentWithProxy.s.sol --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY
 */

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Core contracts
import {ERC1155DualPosition} from "../contracts/DualInvestment/ERC1155DualPosition.sol";
import {VaultExecutor} from "../contracts/DualInvestment/VaultExecutor.sol";
import {SettlementEngine} from "../contracts/DualInvestment/SettlementEngine.sol";
import {CompoundBorrowRouter} from "../contracts/DualInvestment/CompoundBorrowRouter.sol";
import {RiskGuard} from "../contracts/DualInvestment/RiskGuard.sol";
import {DualInvestmentManagerUpgradeable} from "../contracts/DualInvestment/DualInvestmentManagerUpgradeable.sol";

// Proxy infra
import {PeridotProxyAdmin} from "../contracts/proxy/PeridotProxyAdmin.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";

contract DeployDualInvestmentWithProxy is Script {
    // ===== Configuration (update per environment) =====
    address public constant PRICE_ORACLE =
        0xBfEaDDA58d0583f33309AdE83F35A680824E397f;
    address public constant PERIDOTTROLLER =
        0x2e6aeB2AA9B1fC76aCD2E9E5EfeC2bF39C3a9094;
    address public constant PROTOCOL_ACCOUNT =
        0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;

    address public constant PROTOCOL_TREASURY =
        0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9;
    address public constant PROTOCOL_TOKEN =
        0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed;

    address public constant CTOKEN_PWBTC =
        0x08eD77C8A3A48c03fE38A4AdEC2F4204Cf4Fbf1F;
    address public constant CTOKEN_PUSDC =
        0xF0a6303cA0A99d9235979b317E3a78083162a88B;
    address public constant CTOKEN_PUSDT =
        0xC4FE7BD6b9EdD67bF2ba5daa317D7cd80E1913bb;

    uint256 public constant SETTLEMENT_WINDOW = 24 hours;
    uint256 public constant MIN_HEALTH_FACTOR = 1.25e18;
    uint256 public constant MAX_LTV = 0.70e18;
    uint256 public constant MAX_POSITION_SIZE_RATIO = 0.25e18;
    uint256 public constant MAX_POSITION_SIZE = 1000e18;
    uint256 public constant MIN_POSITION_SIZE = 100e8;
    uint256 public constant MAX_EXPIRY = 14 days;
    uint256 public constant MIN_EXPIRY = 1 hours;

    struct DeploymentAddresses {
        address proxyAdmin;
        address managerImpl;
        address manager; // proxy address
        address positionToken;
        address vaultExecutor;
        address settlementEngine;
        address borrowRouter;
        address riskGuard;
    }

    function run() external returns (DeploymentAddresses memory addrs) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== Deploying Dual Investment (proxied manager) ===");
        console.log("Deployer:", deployer);

        require(PRICE_ORACLE != address(0), "PRICE_ORACLE not set");
        require(PERIDOTTROLLER != address(0), "PERIDOTTROLLER not set");
        require(PROTOCOL_ACCOUNT != address(0), "PROTOCOL_ACCOUNT not set");
        require(PROTOCOL_TREASURY != address(0), "PROTOCOL_TREASURY not set");

        vm.startBroadcast(pk);

        // 1) Proxy admin
        PeridotProxyAdmin proxyAdmin = new PeridotProxyAdmin(deployer);
        addrs.proxyAdmin = address(proxyAdmin);
        console.log("ProxyAdmin:", addrs.proxyAdmin);

        // 2) Core components (direct deployments)
        addrs.positionToken = address(new ERC1155DualPosition());
        console.log("ERC1155DualPosition:", addrs.positionToken);

        addrs.vaultExecutor = address(new VaultExecutor(PROTOCOL_ACCOUNT));
        console.log("VaultExecutor:", addrs.vaultExecutor);

        addrs.settlementEngine = address(
            new SettlementEngine(
                addrs.positionToken,
                addrs.vaultExecutor,
                PRICE_ORACLE
            )
        );
        console.log("SettlementEngine:", addrs.settlementEngine);

        addrs.borrowRouter = address(
            new CompoundBorrowRouter(PERIDOTTROLLER, PRICE_ORACLE)
        );
        console.log("CompoundBorrowRouter:", addrs.borrowRouter);

        addrs.riskGuard = address(new RiskGuard(PERIDOTTROLLER, PRICE_ORACLE));
        console.log("RiskGuard:", addrs.riskGuard);

        // 3) Manager implementation + proxy
        addrs.managerImpl = address(new DualInvestmentManagerUpgradeable());
        console.log("Manager implementation:", addrs.managerImpl);

        // Encode initializer data for proxy constructor
        bytes memory initData = abi.encodeWithSelector(
            DualInvestmentManagerUpgradeable.initialize.selector,
            addrs.positionToken,
            addrs.vaultExecutor,
            addrs.settlementEngine,
            addrs.borrowRouter,
            addrs.riskGuard,
            PERIDOTTROLLER,
            PROTOCOL_TREASURY,
            PROTOCOL_TOKEN
        );

        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            addrs.managerImpl,
            addrs.proxyAdmin,
            initData
        );
        addrs.manager = address(proxy);
        console.log("Manager proxy:", addrs.manager);

        // 4) Authorizations: use proxy address for manager everywhere
        ERC1155DualPosition(addrs.positionToken).setAuthorizedMinter(
            addrs.manager,
            true
        );
        ERC1155DualPosition(addrs.positionToken).setAuthorizedMinter(
            addrs.settlementEngine,
            true
        );
        VaultExecutor(addrs.vaultExecutor).setAuthorizedManager(
            addrs.manager,
            true
        );
        VaultExecutor(addrs.vaultExecutor).setAuthorizedManager(
            addrs.settlementEngine,
            true
        );
        CompoundBorrowRouter(addrs.borrowRouter).setAuthorizedDestination(
            addrs.vaultExecutor,
            true
        );

        // 5) Configure params
        SettlementEngine(addrs.settlementEngine).setSettlementWindow(
            SETTLEMENT_WINDOW
        );
        CompoundBorrowRouter(addrs.borrowRouter).setMinHealthFactor(
            MIN_HEALTH_FACTOR
        );
        CompoundBorrowRouter(addrs.borrowRouter).setMaxLTV(MAX_LTV);
        RiskGuard(addrs.riskGuard).setMaxPositionSizeRatio(
            MAX_POSITION_SIZE_RATIO
        );

        // 6) Manager risk params and protocol config via proxy address
        DualInvestmentManagerUpgradeable manager = DualInvestmentManagerUpgradeable(
                addrs.manager
            );
        manager.setRiskParameters(
            MAX_POSITION_SIZE,
            MIN_POSITION_SIZE,
            MAX_EXPIRY,
            MIN_EXPIRY
        );
        // Optionally set protocol fee to 0 initially
        manager.updateProtocolConfig(PROTOCOL_TREASURY, 0, PROTOCOL_TOKEN);

        // 7) Transfer ownership of router/guard to manager (proxy)
        CompoundBorrowRouter(addrs.borrowRouter).transferOwnership(
            addrs.manager
        );
        RiskGuard(addrs.riskGuard).transferOwnership(addrs.manager);

        // 8) Add supported markets and mark integrated
        _addSupported(addrs, manager);

        vm.stopBroadcast();

        _print(addrs);
    }

    function _addSupported(
        DeploymentAddresses memory addrs,
        DualInvestmentManagerUpgradeable manager
    ) internal {
        address[3] memory cTokens = [CTOKEN_PWBTC, CTOKEN_PUSDC, CTOKEN_PUSDT];
        for (uint256 i = 0; i < cTokens.length; i++) {
            if (cTokens[i] != address(0)) {
                manager.setSupportedCToken(cTokens[i], true);
                manager.setMarketIntegration(cTokens[i], true);
                manager.setMarketUtilizationBonus(cTokens[i], 100);
            }
        }
    }

    function _print(DeploymentAddresses memory a) internal view {
        console.log("\n=== Dual Investment (proxied) Deployment ===");
        console.log("ProxyAdmin:", a.proxyAdmin);
        console.log("Manager Impl:", a.managerImpl);
        console.log("Manager Proxy:", a.manager);
        console.log("ERC1155DualPosition:", a.positionToken);
        console.log("VaultExecutor:", a.vaultExecutor);
        console.log("SettlementEngine:", a.settlementEngine);
        console.log("CompoundBorrowRouter:", a.borrowRouter);
        console.log("RiskGuard:", a.riskGuard);
    }
}
