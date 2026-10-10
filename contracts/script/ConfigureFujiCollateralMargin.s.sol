// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {
    CollateralPreservingSettlementModule as Settlement
} from "../contracts/margin/CollateralPreservingSettlementModule.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {MarginInsuranceFundUpgradeable as Insurance} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {FujiMockPharaohVault, FujiMockPharaohRouter} from "../contracts/margin/testing/FujiMockPharaoh.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {PharaohMarginOracle} from "../contracts/margin/PharaohMarginOracle.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Configure only the NEW mock collateral stack; neither entry point unpauses anything.
/// @dev run() queues exactly five actions; execute() consumes them after their stored deadlines while
/// all trading gates stay paused. No feed refresh, deposits, approvals or smoke trades.
contract ConfigureFujiCollateralMargin is Script {
    function run() external {
        _configure(false);
    }

    function execute() external {
        _configure(true);
    }

    function pair() public pure returns (Types.PairRiskConfig memory) {
        // Fuji fixtures, NOT approved production risk: requested trade leverage up to5x.
        return Types.PairRiskConfig(true, 500, 2000, 1000, 12_500, 5000, 5000, 500, 100, 100, 10_000e18, 5000e18);
    }

    function actionIds(address executor) public view returns (bytes32[5] memory ids) {
        Settlement s = Executor(executor).settlement();
        Config c = Config(address(Executor(executor).config()));
        ids[0] = keccak256(abi.encode("fees", uint16(10), uint16(10), uint16(5000), uint16(5000), uint16(0)));
        address[2] memory collateral = [s.pUsdVault(), s.pAvaxVault()];
        for (uint256 i; i < 2; ++i) {
            ids[1 + i * 2] = keccak256(abi.encode("pairRisk", c.pairKey(collateral[i], s.pWavax(), s.pUsd()), pair()));
            ids[2 + i * 2] = keccak256(abi.encode("pairRisk", c.pairKey(collateral[i], s.pUsd(), s.pWavax()), pair()));
        }
    }

    function _configure(bool execute_) private {
        require(block.chainid == 43_113, "CollateralFuji: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", false), "CollateralFuji: confirmation required");
        address owner = vm.envAddress("CP_FUJI_DEPLOYER");
        address executor = vm.envAddress("CP_FUJI_EXECUTOR");
        verify(executor, owner);
        Config c = Config(address(Executor(executor).config()));
        Settlement s = Executor(executor).settlement();
        bytes32[5] memory ids = actionIds(executor);
        // Check the WHOLE batch before starting a broadcast, including on partial reruns.
        for (uint256 i; i < ids.length; ++i) {
            uint256 eta = c.queuedActions(ids[i]);
            require(execute_ ? eta != 0 && block.timestamp >= eta : eta == 0, "CollateralFuji: queue state/time");
        }
        address[2] memory collateral = [s.pUsdVault(), s.pAvaxVault()];
        for (uint256 i; i < 2; ++i) {
            require(
                !c.getPairRisk(collateral[i], s.pWavax(), s.pUsd()).enabled
                    && !c.getPairRisk(collateral[i], s.pUsd(), s.pWavax()).enabled,
                "CollateralFuji: already configured"
            );
        }
        vm.startBroadcast(owner);
        if (execute_) c.setFees(10, 10, 5000, 5000, 0);
        else c.queueFees(10, 10, 5000, 5000, 0);
        for (uint256 i; i < 2; ++i) {
            if (execute_) {
                c.setPairRisk(collateral[i], s.pWavax(), s.pUsd(), pair());
                c.setPairRisk(collateral[i], s.pUsd(), s.pWavax(), pair());
            } else {
                c.queuePairRisk(collateral[i], s.pWavax(), s.pUsd(), pair());
                c.queuePairRisk(collateral[i], s.pUsd(), s.pWavax(), pair());
            }
        }
        vm.stopBroadcast();
        verify(executor, owner);
        console2.log("MOCK ONLY: configuration executed", execute_);
        console2.log("Opens, all market borrows, mock venue and flash lender remain paused. No unpause queued.");
    }

    /// @notice Read-only readiness checks; deliberately does not require fresh prices
    /// while all trading is paused. Activation must separately revalidate prices/capacity.
    function verify(address executor, address owner) public view {
        _verify(executor, owner, false, false, false);
    }

    /// @notice Delay migration may coexist with an already queued unpause, but never activates it.
    /// All other readiness checks, including every pause gate, remain required.
    function verifyDelayTransition(address executor, address owner) external view {
        _verify(executor, owner, true, false, false);
    }

    /// @notice Read-only initial activation checkpoint, before any positions or margin deposits.
    function verifyActivated(address executor, address owner) external view {
        _verify(executor, owner, false, true, false);
    }

    /// @notice Exact first-smoke checkpoint: only the owner's full $60 mock USD pToken deposit exists.
    /// All identity/policy/funding checks remain; this never accepts an existing position or debt.
    function verifySmokeContinuation(address executor, address owner) external view {
        _verify(executor, owner, false, true, true);
    }

    function _verify(address executor, address owner, bool allowQueuedUnpause, bool active, bool usdDeposited)
        private
        view
    {
        require(block.chainid == 43_113 && owner != address(0), "CollateralFuji: identity");
        Executor e = Executor(executor);
        Risk r = e.risk();
        Settlement s = e.settlement();
        Config c = Config(address(e.config()));
        Peridottroller controller = Peridottroller(r.controller());
        require(
            e.executionVersion() == keccak256("collateral-preserving-executor-v1")
                && r.executionVersion() == keccak256("collateral-preserving-risk-v1"),
            "CollateralFuji: fresh stack only"
        );
        require(
            e.nextPositionId() == 1 && r.executor() == executor && e.factory().executor() == executor
                && e.factory().configurator() == owner,
            "CollateralFuji: accounts/wiring"
        );
        require(
            r.owner() == owner && c.owner() == owner && controller.admin() == owner && e.vault().owner() == owner
                && e.vault().executor() == executor,
            "CollateralFuji: owners"
        );
        require(
            controller.isolatedMarginRiskHook() == address(r) && controller.isolatedMarginRegistrar() == address(r),
            "CollateralFuji: controller hook"
        );
        require(
            (c.actionDelay() == 1 hours || c.actionDelay() == 1 days) && c.opensPaused() == !active
                && (allowQueuedUnpause || c.queuedActions(keccak256("unpauseOpens")) == 0),
            "CollateralFuji: pause policy"
        );
        require(
            c.feeImmediateShareBps() == 0 && c.feeStreamDuration() == 7 days && c.treasury() == owner,
            "CollateralFuji: fee policy"
        );
        require(
            r.usdCollateralWeightBps() == 10_000 && r.avaxCollateralWeightBps() == 10_000,
            "CollateralFuji: test weights"
        );
        require(
            s.feeDistributor().owner() == owner && s.feeDistributor().vault() == address(e.vault())
                && address(s.feeDistributor().config()) == address(c),
            "CollateralFuji: rewards"
        );
        require(
            s.feeDistributor().feeCollectors(address(e.vault())) && s.feeDistributor().feeCollectors(address(s)),
            "CollateralFuji: collectors"
        );
        Insurance insurance = Insurance(c.insuranceFund());
        require(insurance.owner() == owner && insurance.liquidator() == executor, "CollateralFuji: insurance");
        require(
            IERC20(s.usd()).balanceOf(address(insurance)) >= 10_000e6
                && IERC20(s.wavax()).balanceOf(address(insurance)) >= 1000e18,
            "CollateralFuji: cash insurance"
        );
        _venue(e, owner, active);
        _oracles(e, owner);
        address[4] memory markets = [s.pUsd(), s.pWavax(), s.pUsdVault(), s.pAvaxVault()];
        for (uint256 i; i < 4; ++i) {
            PErc20 p = PErc20(markets[i]);
            (bool listed, uint256 cf,) = controller.markets(markets[i]);
            require(
                listed && cf == 0 && address(p.peridottroller()) == address(controller) && p.admin() == owner,
                "CollateralFuji: market identity"
            );
            require(
                controller.borrowGuardianPaused(markets[i]) == (!active || i >= 2) && p.flashLoansPaused()
                    && p.totalBorrows() == 0 && p.totalSupply() > 0 && p.getCash() > 0,
                "CollateralFuji: market state"
            );
            require(controller.borrowCaps(markets[i]) > 0, "CollateralFuji: borrow cap");
            if (usdDeposited) {
                uint256 expectedFree = i == 2 ? 3000e8 : 0;
                require(
                    e.vault().totalLockedBalance(markets[i]) == 0 && e.vault().lockedBalance(owner, markets[i]) == 0
                        && e.vault().totalFreeBalance(markets[i]) == expectedFree
                        && e.vault().freeBalance(owner, markets[i]) == expectedFree
                        && IERC20(markets[i]).balanceOf(address(e.vault())) == expectedFree
                        && IERC20(markets[i]).allowance(owner, address(e.vault())) == 0,
                    "CollateralFuji: continuation checkpoint"
                );
            } else {
                require(
                    e.vault().totalLockedBalance(markets[i]) == 0 && e.vault().totalFreeBalance(markets[i]) == 0,
                    "CollateralFuji: nonempty vault"
                );
            }
            require(e.vault().allowedPTokens(markets[i]) == (i >= 2), "CollateralFuji: collateral policy");
            if (i < 2) require(p.borrowAccountingEnabled(), "CollateralFuji: debt accounting");
        }
    }

    function _venue(Executor e, address owner, bool active) private view {
        Settlement s = e.settlement();
        PharaohMarginRouterAdapter a = PharaohMarginRouterAdapter(e.config().routerAdapter());
        PharaohCLRouterAdapter cl = PharaohCLRouterAdapter(address(a.baseRouter()));
        FujiMockPharaohRouter router = FujiMockPharaohRouter(address(cl.router()));
        FujiMockSwapAdapter venue = router.venue();
        SimpleFlashLoanVault lender = SimpleFlashLoanVault(e.config().flashLoanProvider());
        require(
            a.usd() == s.usd() && a.wavax() == s.wavax() && a.usdVault() == s.usdVault()
                && a.avaxVault() == s.avaxVault(),
            "CollateralFuji: adapter assets"
        );
        require(
            cl.usdc() == s.usd() && cl.wavax() == s.wavax() && cl.tickSpacing() == 10
                && cl.pool() == address(cl.factory()) && cl.poolDeployer() == router.deployer(),
            "CollateralFuji: CL binding"
        );
        require(
            router.IS_FUJI_MOCK() && router.owner() == owner && router.operator() == address(cl)
                && venue.operator() == address(router),
            "CollateralFuji: mock router"
        );
        require(
            venue.owner() == owner && venue.paused() == !active && venue.executionBps() == 10_000
                && lender.owner() == owner && lender.paused() == !active && lender.feeBps() == 5,
            "CollateralFuji: venue gates"
        );
        require(
            address(venue.mockUsd()) == s.usd() && address(venue.mockAvax()) == s.wavax()
                && venue.mockUsd().owner() == owner && venue.mockAvax().owner() == owner,
            "CollateralFuji: mock assets"
        );
        require(
            venue.usdFeed().owner() == owner && venue.avaxFeed().owner() == owner && venue.usdFeed().answer() == 1e8
                && venue.avaxFeed().answer() == 10e8,
            "CollateralFuji: mock prices"
        );
        require(lender.tokenAllowed(s.usd()) && lender.tokenAllowed(s.wavax()), "CollateralFuji: lender assets");
        require(
            IERC20(s.usd()).balanceOf(address(lender)) >= 100_000e6
                && IERC20(s.wavax()).balanceOf(address(lender)) >= 10_000e18,
            "CollateralFuji: flash cash"
        );
        require(
            IERC20(s.usd()).balanceOf(address(venue)) >= 1_000_000e6
                && IERC20(s.wavax()).balanceOf(address(venue)) >= 100_000e18,
            "CollateralFuji: venue cash"
        );
        address[2] memory vaults = [s.usdVault(), s.avaxVault()];
        for (uint256 i; i < 2; ++i) {
            FujiMockPharaohVault v = FujiMockPharaohVault(vaults[i]);
            require(
                v.IS_FUJI_MOCK() && v.owner() == owner && v.depositsClosed() && !v.redemptionsClosed(),
                "CollateralFuji: mock vault"
            );
        }
    }

    function _oracles(Executor e, address owner) private view {
        Settlement s = e.settlement();
        PharaohMarginOracle oracle = PharaohMarginOracle(address(e.quoter().oracle()));
        AvalanchePriceOracle base = AvalanchePriceOracle(address(oracle.baseOracle()));
        PharaohVaultShareOracle shares = oracle.shareOracle();
        require(
            base.owner() == owner && shares.owner() == owner && address(shares.baseOracle()) == address(base),
            "CollateralFuji: oracle owners"
        );
        require(
            address(Peridottroller(s.controller()).oracle()) == address(shares), "CollateralFuji: controller oracle"
        );
        require(
            oracle.usdMarket() == s.pUsdVault() && oracle.avaxMarket() == s.pAvaxVault()
                && oracle.usdVault() == s.usdVault() && oracle.avaxVault() == s.avaxVault(),
            "CollateralFuji: share mapping"
        );
        PharaohCLRouterAdapter cl =
            PharaohCLRouterAdapter(address(PharaohMarginRouterAdapter(e.config().routerAdapter()).baseRouter()));
        FujiMockSwapAdapter venue = FujiMockPharaohRouter(address(cl.router())).venue();
        address[2] memory assets = [s.usd(), s.wavax()];
        address[2] memory markets = [s.pUsd(), s.pWavax()];
        address[2] memory vaults = [s.usdVault(), s.avaxVault()];
        address[2] memory expectedFeeds = [address(venue.usdFeed()), address(venue.avaxFeed())];
        for (uint256 i; i < 2; ++i) {
            (address feed, uint32 maxAge, uint8 decimals, bool enabled) = _feed(base, assets[i]);
            require(
                feed == expectedFeeds[i] && maxAge == 1200 && decimals == 8 && enabled
                    && base.marketAsset(markets[i]) == assets[i],
                "CollateralFuji: base feed"
            );
            (uint192 emergency, uint64 expires) = base.emergencyPrices(assets[i]);
            require(emergency == 0 && expires == 0, "CollateralFuji: emergency price");
            (,, uint64 staleness,,,) = shares.vaultConfigs(vaults[i]);
            (address shareFeed, address asset) = _shareFeed(shares, vaults[i]);
            require(
                shareFeed == expectedFeeds[i] && asset == assets[i] && staleness == 1200, "CollateralFuji: share feed"
            );
        }
    }

    function _feed(AvalanchePriceOracle oracle, address asset) private view returns (address, uint32, uint8, bool) {
        (AggregatorV3Interface feed, uint32 age, uint8 decimals, bool enabled) = oracle.feeds(asset);
        return (address(feed), age, decimals, enabled);
    }

    function _shareFeed(PharaohVaultShareOracle oracle, address vault) private view returns (address, address) {
        (AggregatorV3Interface feed, address asset,,,,) = oracle.vaultConfigs(vault);
        return (address(feed), asset);
    }
}
