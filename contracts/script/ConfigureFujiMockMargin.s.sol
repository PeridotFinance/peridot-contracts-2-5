// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FujiMockToken, FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";

/// @notice Queues/executes 2x MOCK-asset test pairs. Never use as the real-token Fuji activation path.
/// @dev Activation is separately opt-in, timelocked and restricted to an owner-controlled mock environment.
contract ConfigureFujiMockMargin is Script {
    function run() external {
        require(block.chainid == 43_113, "ConfigureMock: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "ConfigureMock: confirmation required");
        address owner = vm.envAddress("MOCK_MARGIN_DEPLOYER");
        IsolatedMarginRiskEngineUpgradeable risk =
            IsolatedMarginRiskEngineUpgradeable(vm.envAddress("MOCK_RISK_ENGINE"));
        IsolatedMarginConfigUpgradeable config = IsolatedMarginConfigUpgradeable(address(risk.config()));
        Peridottroller controller = Peridottroller(risk.controller());
        PErc20 avax = PErc20(vm.envAddress("MOCK_PAVAX"));
        PErc20 usd = PErc20(vm.envAddress("MOCK_PUSD"));
        FujiMockSwapAdapter adapter = FujiMockSwapAdapter(config.routerAdapter());
        SimpleFlashLoanVault lender = SimpleFlashLoanVault(config.flashLoanProvider());
        require(
            owner != address(0) && config.owner() == owner && risk.owner() == owner && controller.admin() == owner
                && adapter.owner() == owner && lender.owner() == owner,
            "ConfigureMock: wrong owner"
        );
        require(adapter.IS_FUJI_MOCK(), "ConfigureMock: not mock venue");
        require(
            address(avax.peridottroller()) == address(controller)
                && address(usd.peridottroller()) == address(controller),
            "ConfigureMock: mixed controllers"
        );
        require(
            avax.underlying() == address(adapter.mockAvax()) && usd.underlying() == address(adapter.mockUsd()),
            "ConfigureMock: wrong assets"
        );
        require(
            adapter.mockAvax().owner() == owner && adapter.mockUsd().owner() == owner
                && adapter.avaxFeed().owner() == owner && adapter.usdFeed().owner() == owner,
            "ConfigureMock: not controlled mocks"
        );
        require(
            controller.isolatedMarginRiskHook() == address(risk)
                && controller.isolatedMarginRegistrar() == address(risk),
            "ConfigureMock: wiring"
        );
        require(
            risk.oracle().marketAsset(address(avax)) == avax.underlying()
                && risk.oracle().marketAsset(address(usd)) == usd.underlying(),
            "ConfigureMock: oracle assets"
        );
        _validateFeeds(AvalanchePriceOracle(address(risk.oracle())), adapter);
        _validateFeeds(AvalanchePriceOracle(address(controller.oracle())), adapter);
        require(
            address(IsolatedMarginExecutorUpgradeable(risk.executor()).swapModule()) == adapter.operator(),
            "ConfigureMock: operator wiring"
        );
        require(
            config.opensPaused() && config.feeImmediateShareBps() == 0 && config.feeStreamDuration() == 7 days,
            "ConfigureMock: launch policy"
        );
        (, uint256 avaxCf,) = controller.markets(address(avax));
        (, uint256 usdCf,) = controller.markets(address(usd));
        require(
            avaxCf == 0 && usdCf == 0 && controller.borrowCaps(address(avax)) > 0
                && controller.borrowCaps(address(usd)) > 0,
            "ConfigureMock: lending policy"
        );

        bool execute = vm.envOr("MOCK_EXECUTE", false);
        bool enable = vm.envOr("MOCK_ENABLE_TRADING", false);
        IsolatedMarginTypes.PairRiskConfig memory pair = IsolatedMarginTypes.PairRiskConfig(
            true, 200, 5000, 3500, 12_500, 5000, 5000, 500, 100, 100, 10_000e18, 5000e18
        );
        vm.startBroadcast(owner);
        // Explicitly refresh mock rounds, preserving the operator's selected scenario prices.
        adapter.avaxFeed().setAnswer(adapter.avaxFeed().answer());
        adapter.usdFeed().setAnswer(adapter.usdFeed().answer());
        if (!execute) {
            config.queuePairRisk(address(usd), address(avax), address(usd), pair);
            config.queuePairRisk(address(usd), address(usd), address(avax), pair);
            if (enable) config.queueUnpauseOpens();
            console2.log("MOCK pair actions queued; wait at least", config.actionDelay());
        } else {
            config.setPairRisk(address(usd), address(avax), address(usd), pair);
            config.setPairRisk(address(usd), address(usd), address(avax), pair);
            if (enable) {
                _activationChecks(risk, adapter, lender, avax, usd);
                adapter.setPaused(false);
                lender.setPaused(false);
                require(!controller._setBorrowPaused(PToken(address(avax)), false), "ConfigureMock: AVAX borrowing");
                require(!controller._setBorrowPaused(PToken(address(usd)), false), "ConfigureMock: USD borrowing");
                config.unpauseOpens();
            }
            console2.log("MOCK pair actions executed; trading enabled", enable);
        }
        vm.stopBroadcast();
    }

    function _activationChecks(
        IsolatedMarginRiskEngineUpgradeable risk,
        FujiMockSwapAdapter adapter,
        SimpleFlashLoanVault lender,
        PErc20 avax,
        PErc20 usd
    ) private view {
        require(adapter.paused() && lender.paused() && adapter.operator().code.length > 0, "ConfigureMock: venue state");
        require(adapter.executionBps() == 10_000, "ConfigureMock: initial execution haircut");
        require(
            risk.oracle().getPrice(avax.underlying()) > 0 && risk.oracle().getPrice(usd.underlying()) > 0,
            "ConfigureMock: margin prices"
        );
        require(
            Peridottroller(risk.controller()).oracle().getUnderlyingPrice(PToken(address(avax))) > 0
                && Peridottroller(risk.controller()).oracle().getUnderlyingPrice(PToken(address(usd))) > 0,
            "ConfigureMock: lending prices"
        );
        require(
            lender.tokenAllowed(avax.underlying()) && lender.tokenAllowed(usd.underlying()),
            "ConfigureMock: lender tokens"
        );
        // Finite test budgets, not a promise that every configured position cap has sufficient venue liquidity.
        require(
            adapter.mockAvax().balanceOf(address(lender)) >= 100e18
                && adapter.mockUsd().balanceOf(address(lender)) >= 1000e6,
            "ConfigureMock: flash liquidity"
        );
        require(
            adapter.mockAvax().balanceOf(address(adapter)) >= 100e18
                && adapter.mockUsd().balanceOf(address(adapter)) >= 1000e6,
            "ConfigureMock: swap liquidity"
        );
        require(
            avax.balanceOf(risk.config().insuranceFund()) > 0 && usd.balanceOf(risk.config().insuranceFund()) > 0,
            "ConfigureMock: insurance"
        );
    }

    function _validateFeeds(AvalanchePriceOracle oracle, FujiMockSwapAdapter adapter) private view {
        (AggregatorV3Interface avaxFeed, uint32 avaxAge,, bool avaxEnabled) = oracle.feeds(address(adapter.mockAvax()));
        (AggregatorV3Interface usdFeed, uint32 usdAge,, bool usdEnabled) = oracle.feeds(address(adapter.mockUsd()));
        require(
            address(avaxFeed) == address(adapter.avaxFeed()) && address(usdFeed) == address(adapter.usdFeed())
                && avaxAge == 1200 && usdAge == 1200 && avaxEnabled && usdEnabled,
            "ConfigureMock: mismatched feeds"
        );
    }
}
