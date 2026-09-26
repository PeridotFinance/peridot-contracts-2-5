// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FujiMockToken, FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {
    FujiMockPharaohVault,
    FujiMockPharaohBinding,
    FujiMockPharaohRouter
} from "../contracts/margin/testing/FujiMockPharaoh.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {Peridot} from "../contracts/Governance/Peridot.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerAvalancheFuji} from "../contracts/PeridottrollerAvalancheFuji.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";
import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {AvalancheFujiMarketBootstrapper} from "../contracts/deployment/AvalancheFujiMarketBootstrapper.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PharaohMarginOracle} from "../contracts/margin/PharaohMarginOracle.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {MarginFeeDistributorUpgradeable as Fees} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable as Insurance} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable as Vault} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginQuoter as Quoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {CollateralPreservingSwapModule as Swap} from "../contracts/margin/CollateralPreservingSwapModule.sol";
import {
    CollateralPreservingSettlementModule as Settlement
} from "../contracts/margin/CollateralPreservingSettlementModule.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {IsolatedMarginAccountFactory as Factory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";

/// @notice Entirely NEW mock-only Fuji collateral-preserving environment. No legacy upgrades.
/// @dev Inputs are CP_FUJI_DEPLOYER and CONFIRM_FUJI_COLLATERAL_MOCK_ONLY only.
/// No keys, existing addresses, environment rewriting, queueing or activation.
contract DeployFujiCollateralMargin is Script {
    struct Deployment {
        FujiMockToken usd;
        FujiMockToken avax;
        FujiMockPriceFeed usdFeed;
        FujiMockPriceFeed avaxFeed;
        FujiMockPharaohVault usdVault;
        FujiMockPharaohVault avaxVault;
        FujiMockSwapAdapter venue;
        FujiMockPharaohBinding binding;
        FujiMockPharaohRouter router;
        PharaohCLRouterAdapter cl;
        PharaohMarginRouterAdapter adapter;
        SimpleFlashLoanVault lender;
        Peridot peridot;
        Unitroller unitroller;
        PeridottrollerAvalancheFuji implementation;
        Peridottroller controller;
        ConfigurableJumpRateModelV2 interest;
        address plainDelegate;
        address boostedDelegate;
        AvalancheFujiMarketBootstrapper plainBootstrap;
        AvalancheFujiMarketBootstrapper boostedBootstrap;
        PErc20Delegator pUsd;
        PErc20Delegator pAvax;
        PErc20Delegator pUsdVault;
        PErc20Delegator pAvaxVault;
        AvalanchePriceOracle baseOracle;
        PharaohVaultShareOracle shareOracle;
        PharaohMarginOracle oracle;
        Insurance insurance;
        Config config;
        Fees fees;
        Vault vault;
        Quoter quoter;
        Swap swapModule;
        Settlement settlement;
        Risk risk;
        Factory factory;
        Executor executor;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == 43_113, "CollateralFuji: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", false), "CollateralFuji: confirmation required");
        address owner = vm.envAddress("CP_FUJI_DEPLOYER");
        require(owner != address(0), "CollateralFuji: zero owner");
        vm.startBroadcast(owner);
        _assets(d, owner);
        _lending(d, owner);
        _execution(d, owner);
        // Cash insurance is independent of the pToken fees the fund may later receive.
        d.usd.mint(address(d.insurance), 10_000e6);
        d.avax.mint(address(d.insurance), 1000e18);
        vm.stopBroadcast();
        require(d.config.opensPaused() && d.venue.paused() && d.lender.paused(), "CollateralFuji: pause gates");
        address[4] memory markets = [address(d.pUsd), address(d.pAvax), address(d.pUsdVault), address(d.pAvaxVault)];
        for (uint256 i; i < 4; ++i) {
            require(d.controller.borrowGuardianPaused(markets[i]), "CollateralFuji: borrowing active");
        }
        console2.log("FRESH FUJI MOCK ONLY - not real Pharaoh, Chainlink, USDC or WAVAX");
        console2.log("Controller", address(d.controller));
        console2.log("mockUSD / mockAVAX", address(d.usd), address(d.avax));
        console2.log("MOCK USD / AVAX vaults", address(d.usdVault), address(d.avaxVault));
        console2.log("pUSD / pAVAX", address(d.pUsd), address(d.pAvax));
        console2.log("pUSD vault / pAVAX vault", address(d.pUsdVault), address(d.pAvaxVault));
        console2.log("Margin executor", address(d.executor));
        console2.log("Margin risk / config", address(d.risk), address(d.config));
        console2.log("Margin vault / fee distributor", address(d.vault), address(d.fees));
        console2.log("Cash insurance", address(d.insurance));
        console2.log("No queued actions. All trading gates paused. Verify receipts before configuration.");
    }

    function _assets(Deployment memory d, address owner) private {
        d.usd = new FujiMockToken(owner, true);
        d.avax = new FujiMockToken(owner, false);
        d.usdFeed = new FujiMockPriceFeed(owner, true);
        d.avaxFeed = new FujiMockPriceFeed(owner, false);
        d.usdVault = new FujiMockPharaohVault(owner, d.usd);
        d.avaxVault = new FujiMockPharaohVault(owner, d.avax);
        d.usd.mint(owner, 120_000e6);
        d.avax.mint(owner, 12_000e18);
        d.usd.approve(address(d.usdVault), 10_000e6);
        d.avax.approve(address(d.avaxVault), 1000e18);
        require(d.usdVault.deposit(10_000e6, owner) == 10_000e6, "CollateralFuji: USD shares");
        require(d.avaxVault.deposit(1000e18, owner) == 1000e18, "CollateralFuji: AVAX shares");
        d.usd.approve(address(d.usdVault), 0);
        d.avax.approve(address(d.avaxVault), 0);
        d.usdVault.setLimits(true, false);
        d.avaxVault.setLimits(true, false);
        d.venue = new FujiMockSwapAdapter(owner, d.avax, d.usd, d.avaxFeed, d.usdFeed);
        d.binding = new FujiMockPharaohBinding(address(d.avax), address(d.usd));
        d.router = new FujiMockPharaohRouter(owner, address(d.binding), d.venue);
        d.cl = new PharaohCLRouterAdapter(
            address(d.router), address(d.binding), address(d.binding), address(d.avax), address(d.usd), 10
        );
        d.router.setOperator(address(d.cl));
        d.venue.setOperator(address(d.router));
        d.adapter = new PharaohMarginRouterAdapter(
            address(d.usdVault), address(d.avaxVault), address(d.usd), address(d.avax), address(d.cl)
        );
        d.lender = new SimpleFlashLoanVault(owner);
        d.lender.setPaused(true);
        d.lender.setTokenAllowed(address(d.usd), true);
        d.lender.setTokenAllowed(address(d.avax), true);
        d.usd.mint(address(d.venue), 1_000_000e6);
        d.avax.mint(address(d.venue), 100_000e18);
        d.usd.mint(address(d.lender), 100_000e6);
        d.avax.mint(address(d.lender), 10_000e18);
    }

    function _lending(Deployment memory d, address owner) private {
        d.peridot = new Peridot(owner);
        d.unitroller = new Unitroller();
        d.implementation = new PeridottrollerAvalancheFuji(address(d.peridot));
        require(
            d.unitroller._setPendingImplementation(address(d.implementation)) == 0, "CollateralFuji: implementation"
        );
        d.implementation._become(d.unitroller);
        d.controller = Peridottroller(address(d.unitroller));
        d.interest = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, owner);
        d.plainDelegate = address(new PErc20Delegate());
        d.boostedDelegate = address(new PharaohBoostedDelegate());
        d.controller._setPauseGuardian(owner);
        require(d.controller._setCloseFactor(0.5e18) == 0, "CollateralFuji: close factor");
        require(d.controller._setLiquidationIncentive(1.08e18) == 0, "CollateralFuji: incentive");
        _seedPair(d, owner, false);
        _seedPair(d, owner, true);
        d.baseOracle = new AvalanchePriceOracle(owner);
        d.baseOracle.configureFeed(address(d.usd), address(d.usdFeed), 1200);
        d.baseOracle.configureFeed(address(d.avax), address(d.avaxFeed), 1200);
        d.baseOracle.registerMarket(address(d.pUsd), address(d.usd));
        d.baseOracle.registerMarket(address(d.pAvax), address(d.avax));
        d.shareOracle = new PharaohVaultShareOracle(owner, d.baseOracle);
        d.shareOracle.registerVault(d.usdVault, d.usdFeed, 1200);
        d.shareOracle.registerVault(d.avaxVault, d.avaxFeed, 1200);
        require(d.controller._setPriceOracle(d.shareOracle) == 0, "CollateralFuji: oracle");
        d.oracle = new PharaohMarginOracle(
            d.baseOracle,
            d.shareOracle,
            address(d.pUsdVault),
            address(d.usdVault),
            address(d.pAvaxVault),
            address(d.avaxVault)
        );
    }

    /// @dev Reuse the single-use atomic list/seed/pause bootstrapper twice. Its
    /// pinned underlying checks work for both 6/18-decimal mock tokens and shares.
    function _seedPair(Deployment memory d, address owner, bool boosted) private {
        address a = boosted ? address(d.avaxVault) : address(d.avax);
        address u = boosted ? address(d.usdVault) : address(d.usd);
        address delegate = boosted ? d.boostedDelegate : d.plainDelegate;
        AvalancheFujiMarketBootstrapper bootstrap =
            new AvalancheFujiMarketBootstrapper(owner, address(d.controller), address(d.interest), delegate, a, u);
        PErc20Delegator pa = new PErc20Delegator(
            a,
            d.controller,
            d.interest,
            2e26,
            "MOCK AVAX collateral market - Fuji",
            boosted ? "pMockPHAR-A" : "pMockAVAX",
            8,
            payable(address(bootstrap)),
            delegate,
            boosted ? abi.encode(a, uint256(1)) : bytes("")
        );
        PErc20Delegator pu = new PErc20Delegator(
            u,
            d.controller,
            d.interest,
            2e14,
            "MOCK USD collateral market - Fuji",
            boosted ? "pMockPHAR-U" : "pMockUSD",
            8,
            payable(address(bootstrap)),
            delegate,
            boosted ? abi.encode(u, uint256(1)) : bytes("")
        );
        uint256 aSeed = boosted ? 1000e18 : 10_000e18;
        uint256 uSeed = boosted ? 10_000e6 : 100_000e6;
        require(d.unitroller._setPendingAdmin(address(bootstrap)) == 0, "CollateralFuji: pending admin");
        IERC20(a).approve(address(bootstrap), aSeed);
        IERC20(u).approve(address(bootstrap), uSeed);
        bootstrap.bootstrap(address(pa), address(pu), aSeed, uSeed, aSeed * 5, uSeed * 5, 0.1e18);
        IERC20(a).approve(address(bootstrap), 0);
        IERC20(u).approve(address(bootstrap), 0);
        require(
            d.unitroller._acceptAdmin() == 0 && pa._acceptAdmin() == 0 && pu._acceptAdmin() == 0,
            "CollateralFuji: accept admin"
        );
        if (boosted) {
            d.pAvaxVault = pa;
            d.pUsdVault = pu;
            d.boostedBootstrap = bootstrap;
        } else {
            d.pAvax = pa;
            d.pUsd = pu;
            d.plainBootstrap = bootstrap;
        }
    }

    function _execution(Deployment memory d, address owner) private {
        d.insurance = Insurance(_proxy(address(new Insurance()), owner, abi.encodeCall(Insurance.initialize, (owner))));
        d.config = Config(
            _proxy(
                address(new Config()),
                owner,
                abi.encodeCall(
                    Config.initialize,
                    (owner, 1 days, address(d.adapter), address(d.lender), address(d.insurance), owner)
                )
            )
        );
        d.fees = Fees(_proxy(address(new Fees()), owner, abi.encodeCall(Fees.initialize, (owner, address(d.config)))));
        d.vault = Vault(_proxy(address(new Vault()), owner, abi.encodeCall(Vault.initialize, (owner, address(d.fees)))));
        d.fees.setVault(address(d.vault));
        d.fees.setFeeCollector(address(d.vault), true);
        d.vault.setPTokenAllowed(address(d.pUsdVault), true);
        d.vault.setPTokenAllowed(address(d.pAvaxVault), true);
        d.quoter = new Quoter(address(d.config), address(d.oracle));
        d.swapModule = new Swap(address(d.config), address(d.quoter));
        d.settlement = new Settlement(
            address(d.config),
            address(d.quoter),
            address(d.swapModule),
            address(d.fees),
            Settlement.Markets(
                address(d.usd),
                address(d.avax),
                address(d.pUsd),
                address(d.pAvax),
                address(d.pUsdVault),
                address(d.pAvaxVault)
            )
        );
        d.fees.setFeeCollector(address(d.settlement), true);
        // Test-only valuation weights, not approved mainnet risk parameters.
        d.risk = new Risk(owner, address(d.settlement), 10_000, 10_000);
        d.factory = new Factory(owner);
        d.executor = new Executor(address(d.risk), address(d.vault), address(d.factory));
        d.factory.setExecutor(address(d.executor));
        d.risk.setExecutor(address(d.executor));
        d.vault.setExecutor(address(d.executor));
        d.insurance.setLiquidator(address(d.executor));
        require(d.controller._setIsolatedMarginRegistrar(address(d.risk)) == 0, "CollateralFuji: registrar");
        require(d.controller._setIsolatedMarginRiskHook(address(d.risk)) == 0, "CollateralFuji: risk hook");
    }

    function _proxy(address implementation, address owner, bytes memory data) private returns (address) {
        return address(new PeridotTransparentProxy(implementation, owner, data));
    }
}
