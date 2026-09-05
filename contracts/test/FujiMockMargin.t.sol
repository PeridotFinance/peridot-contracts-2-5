// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FujiMockToken, FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {DeployFujiMockMargin} from "../script/DeployFujiMockMargin.s.sol";
import {ConfigureFujiMockMargin} from "../script/ConfigureFujiMockMargin.s.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {PToken} from "../contracts/PToken.sol";

contract FujiMockAssetsTest is Test {
    FujiMockToken avax;
    FujiMockToken usd;
    FujiMockPriceFeed avaxFeed;
    FujiMockPriceFeed usdFeed;
    FujiMockSwapAdapter adapter;

    function setUp() public {
        vm.chainId(43_113);
        vm.warp(1_000_000);
        avax = new FujiMockToken(address(this), false);
        usd = new FujiMockToken(address(this), true);
        avaxFeed = new FujiMockPriceFeed(address(this), false);
        usdFeed = new FujiMockPriceFeed(address(this), true);
        adapter = new FujiMockSwapAdapter(address(this), avax, usd, avaxFeed, usdFeed);
    }

    function testOnlyFujiAndExplicitDeploymentConfirmation() public {
        vm.chainId(43_114);
        vm.expectRevert("FujiMock: Fuji only");
        new FujiMockToken(address(this), true);
        vm.expectRevert("FujiMock: Fuji only");
        new FujiMockPriceFeed(address(this), true);
        vm.expectRevert("FujiMock: Fuji only");
        new FujiMockSwapAdapter(address(this), avax, usd, avaxFeed, usdFeed);
        DeployFujiMockMargin script = new DeployFujiMockMargin();
        vm.expectRevert("DeployMockMargin: Fuji only");
        script.run();
        vm.chainId(43_113);
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("DeployMockMargin: confirmation required");
        script.run();
    }

    function testOnlyOwnerCanMintMovePricesOrConfigureVenue() public {
        vm.startPrank(address(123));
        vm.expectRevert();
        usd.mint(address(123), 1e6);
        vm.expectRevert();
        avaxFeed.setAnswer(20e8);
        vm.expectRevert();
        adapter.setExecutionBps(9000);
        vm.expectRevert();
        adapter.setPaused(false);
        vm.expectRevert();
        adapter.setOperator(address(this));
        vm.stopPrank();
    }

    function testMintAndPriceBoundsAndClearMockLabels() public {
        assertEq(usd.decimals(), 6);
        assertEq(avax.decimals(), 18);
        assertEq(usd.symbol(), "mockUSD");
        assertEq(avax.symbol(), "mockAVAX");
        assertEq(avaxFeed.description(), "MOCK AVAX / USD");
        usd.mint(address(this), usd.supplyCap());
        vm.expectRevert("FujiMock: supply cap");
        usd.mint(address(this), 1);
        vm.expectRevert("FujiMock: price bounds");
        avaxFeed.setAnswer(0);
        vm.expectRevert("FujiMock: price bounds");
        avaxFeed.setAnswer(1_000_000e8 + 1);
        vm.expectRevert("FujiMock: execution bounds");
        adapter.setExecutionBps(10_001);
    }

    function testQuotesBothDecimalsAndControlledPriceMove() public {
        assertEq(adapter.quote(address(usd), address(avax), 100e6), 10e18);
        assertEq(adapter.quote(address(avax), address(usd), 10e18), 100e6);
        avaxFeed.setAnswer(20e8);
        assertEq(adapter.quote(address(usd), address(avax), 100e6), 5e18);
        assertEq(adapter.quote(address(avax), address(usd), 10e18), 200e6);
        vm.warp(block.timestamp + 1201);
        vm.expectRevert("FujiMock: stale price");
        adapter.quote(address(usd), address(avax), 1e6);
    }

    function testFundedSwapAndVictimAllowanceProtection() public {
        adapter.setOperator(address(this));
        adapter.setPaused(false);
        usd.mint(address(this), 100e6);
        avax.mint(address(adapter), 10e18);
        usd.approve(address(adapter), 100e6);
        vm.expectRevert("FujiMock: unauthorized payer");
        adapter.swap(address(123), address(usd), address(avax), 100e6, 0, "");
        assertEq(adapter.swap(address(this), address(usd), address(avax), 100e6, 10e18, ""), 10e18);
        assertEq(avax.balanceOf(address(this)), 10e18);
        assertEq(usd.balanceOf(address(adapter)), 100e6);
        vm.expectRevert("FujiMock: operator already set or invalid");
        adapter.setOperator(address(this));
    }

    function testLiquidityMinimumAndUnsupportedPairFailClosed() public {
        adapter.setOperator(address(this));
        adapter.setPaused(false);
        vm.expectRevert("FujiMock: insufficient liquidity");
        adapter.swap(address(this), address(usd), address(avax), 1e6, 0, "");
        vm.expectRevert("FujiMock: unsupported pair");
        adapter.quote(address(usd), address(usd), 1);
        adapter.setExecutionBps(9800);
        vm.expectRevert("FujiMock: minimum output");
        adapter.swap(address(this), address(usd), address(avax), 1e6, 0.099e18, "");
    }

    function testFuzzQuoteRoundTripNeverCreatesTokens(uint256 amount, uint256 price) public {
        amount = bound(amount, 1, 1_000_000e6);
        price = bound(price, 1e6, 1_000_000e8);
        avaxFeed.setAnswer(int256(price));
        uint256 out = adapter.quote(address(usd), address(avax), amount);
        assertLe(adapter.quote(address(avax), address(usd), out), amount);
    }
}

contract FujiMockMarginLifecycleTest is Test {
    DeployFujiMockMargin.Environment e;
    address constant USER = address(0xA11CE);
    uint256 constant MARGIN_SHARES = 5000e8; // 100 mockUSD, pToken exchange rate 2e14

    function setUp() public {
        vm.chainId(43_113);
        vm.warp(1_000_000);
        vm.setEnv("MOCK_MARGIN_DEPLOYER", vm.toString(address(this)));
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        // Poison existing deployment inputs: the isolated mock script must never consume them.
        vm.setEnv("PERIDOTTROLLER", vm.toString(address(0xBAD)));
        vm.setEnv("MARGIN_ROUTER_ADAPTER", vm.toString(address(0xBAD)));
        e = new DeployFujiMockMargin().run();
        e.lending.pUsdc.transfer(USER, MARGIN_SHARES * 10);
        vm.startPrank(USER);
        e.lending.pUsdc.approve(address(e.margin.vault), MARGIN_SHARES * 10);
        e.margin.vault.deposit(address(e.lending.pUsdc), MARGIN_SHARES * 10);
        vm.stopPrank();
    }

    function testDeploymentIsFreshFundedAndPaused() public view {
        assertEq(e.lending.unitroller.admin(), address(this));
        assertEq(e.lending.pWavax.admin(), address(this));
        assertEq(e.lending.pUsdc.admin(), address(this));
        assertEq(e.lending.pUsdc.symbol(), "pMockUSD");
        assertEq(e.lending.pWavax.symbol(), "pMockAVAX");
        assertTrue(e.margin.config.opensPaused() && e.adapter.paused() && e.lender.paused());
        assertTrue(e.lending.controller.borrowGuardianPaused(address(e.lending.pWavax)));
        assertTrue(e.lending.controller.borrowGuardianPaused(address(e.lending.pUsdc)));
        assertTrue(e.lending.pWavax.flashLoansPaused() && e.lending.pUsdc.flashLoansPaused());
        assertEq(e.lending.pWavax.getCash(), 10_000e18);
        assertEq(e.lending.pUsdc.getCash(), 100_000e6);
        assertEq(e.lending.controller.borrowCaps(address(e.lending.pWavax)), 50_000e18);
        assertEq(e.lending.controller.borrowCaps(address(e.lending.pUsdc)), 500_000e6);
        assertEq(e.avax.balanceOf(address(e.lender)), 10_000e18);
        assertEq(e.usd.balanceOf(address(e.lender)), 100_000e6);
        assertGt(e.lending.pUsdc.balanceOf(address(e.margin.insuranceFund)), 0);
        assertEq(e.margin.config.feeImmediateShareBps(), 0);
        assertEq(e.margin.config.feeStreamDuration(), 7 days);
        assertEq(e.avax.allowance(address(this), address(e.lending.bootstrapper)), 0);
        assertEq(e.usd.allowance(address(this), address(e.lending.bootstrapper)), 0);
    }

    function testTwoXLongAndShortRoundTripsReturnPTokens() public {
        _configureScriptInputs(true);
        ConfigureFujiMockMargin script = new ConfigureFujiMockMargin();
        script.run();
        vm.setEnv("MOCK_EXECUTE", "true");
        vm.expectRevert(); // Cannot bypass the actual one-day delay.
        script.run();
        vm.stopBroadcast(); // Expected script revert leaves this Foundry cheatcode state active.
        vm.warp(block.timestamp + 1 days);
        script.run();
        _roundTrip(false, 200);
        _roundTrip(true, 200);
    }

    function testConfigurationDefaultsDoNotEnableTradingAndRejectMixedMarkets() public {
        _configureScriptInputs(false);
        ConfigureFujiMockMargin script = new ConfigureFujiMockMargin();
        script.run();
        vm.warp(block.timestamp + 1 days);
        vm.setEnv("MOCK_EXECUTE", "true");
        script.run();
        assertTrue(e.margin.config.opensPaused() && e.adapter.paused() && e.lender.paused());
        assertTrue(e.lending.controller.borrowGuardianPaused(address(e.lending.pUsdc)));
        vm.setEnv("MOCK_PAVAX", vm.toString(address(e.lending.pUsdc)));
        vm.expectRevert("ConfigureMock: wrong assets");
        script.run();
        vm.chainId(43_114);
        vm.expectRevert("ConfigureMock: Fuji only");
        script.run();
    }

    function testFeeRewardsRemainInMockCollateralPTokensAndStream() public {
        e.margin.config.queueFees(10, 10, 5000, 5000, 0);
        _activate(500);
        e.margin.config.setFees(10, 10, 5000, 5000, 0);
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 500);
        params.maxOpeningFeePToken = MARGIN_SHARES / 100;
        vm.prank(USER);
        e.margin.executor.openPosition(params);
        assertLt(
            e.margin.feeDistributor.pendingRewards(USER, address(e.lending.pUsdc)), e.margin.config.feeStreamDuration()
        );
        vm.warp(block.timestamp + 7 days);
        uint256 reward = e.margin.feeDistributor.pendingRewards(USER, address(e.lending.pUsdc));
        assertGt(reward, 0);
        uint256 before = e.margin.vault.freeBalance(USER, address(e.lending.pUsdc));
        vm.prank(USER);
        e.margin.vault.settle(address(e.lending.pUsdc));
        assertEq(e.margin.vault.freeBalance(USER, address(e.lending.pUsdc)), before + reward);
    }

    function _configureScriptInputs(bool enable) private {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("MOCK_RISK_ENGINE", vm.toString(address(e.margin.riskEngine)));
        vm.setEnv("MOCK_PAVAX", vm.toString(address(e.lending.pWavax)));
        vm.setEnv("MOCK_PUSD", vm.toString(address(e.lending.pUsdc)));
        vm.setEnv("MOCK_EXECUTE", "false");
        vm.setEnv("MOCK_ENABLE_TRADING", enable ? "true" : "false");
    }

    function testFiveXLongAndShortHealthyAtZeroSpotCollateralFactor() public {
        _activate(500);
        _roundTrip(false, 500);
        _roundTrip(true, 500);
    }

    function testInterestAccruesAndIncreasesSupplyValue() public {
        _activate(500);
        uint256 id = _open(false, 500);
        IsolatedMarginTypes.Position memory p = _position(id);
        uint256 debt = e.lending.pUsdc.borrowBalanceStored(p.account);
        uint256 exchange = e.lending.pUsdc.exchangeRateStored();
        vm.roll(block.number + 100_000);
        assertGt(e.lending.pUsdc.borrowBalanceCurrent(p.account), debt);
        assertGt(e.lending.pUsdc.exchangeRateStored(), exchange);
        assertEq(e.margin.vault.lockedBalance(USER, address(e.lending.pUsdc)), MARGIN_SHARES);
    }

    function testSlippageRevertIsAtomicAndNormalSpotCannotBorrow() public {
        _activate(200);
        e.adapter.setExecutionBps(9800);
        uint256 free = e.margin.vault.freeBalance(USER, address(e.lending.pUsdc));
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 200);
        vm.prank(USER);
        vm.expectRevert("FujiMock: minimum output");
        e.margin.executor.openPosition(params);
        assertEq(e.margin.vault.freeBalance(USER, address(e.lending.pUsdc)), free);
        assertEq(e.margin.vault.lockedBalance(USER, address(e.lending.pUsdc)), 0);
        assertEq(e.lending.pUsdc.totalBorrows(), 0);
        vm.prank(USER);
        vm.expectRevert();
        e.lending.pUsdc.borrow(1e6);
    }

    function testStaleOracleStillAllowsDebtFreePTokenExit() public {
        _activate(200);
        uint256 id = _open(false, 200);
        e.usd.mint(USER, 200e6);
        vm.startPrank(USER);
        e.usd.approve(address(e.margin.executor), type(uint256).max);
        e.margin.executor.repayWithUnderlying(id, type(uint256).max);
        vm.stopPrank();
        vm.warp(block.timestamp + 1201);
        assertEq(e.margin.oracle.getPrice(address(e.avax)), 0);
        vm.prank(USER);
        e.margin.executor.exitDebtFreeToPTokens(id, 0);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertGt(e.lending.pWavax.balanceOf(USER), 0);
    }

    function testPriceDropPartialLiquidationImprovesHealth() public {
        _activate(500);
        uint256 id = _open(false, 500);
        address account = _position(id).account;
        e.avaxFeed.setAnswer(8.8e8);
        uint256 health = e.margin.riskEngine.getMetrics(account).healthFactorBps;
        assertTrue(e.margin.riskEngine.isLiquidatable(account));
        e.margin.liquidator.liquidate(_liquidation(id));
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.ACTIVE));
        assertGt(e.margin.riskEngine.getMetrics(account).healthFactorBps, health);
    }

    function testPriceCrashAndShortSqueezeClearDebtUsingInsurance() public {
        _activate(500);
        uint256 id = _open(false, 500);
        e.avaxFeed.setAnswer(7.5e8);
        _assertFullLiquidation(id);
        e.avaxFeed.setAnswer(10e8);
        id = _open(true, 500);
        e.avaxFeed.setAnswer(15e8);
        _assertFullLiquidation(id);
    }

    function _assertFullLiquidation(uint256 id) private {
        IsolatedMarginTypes.Position memory p = _position(id);
        assertTrue(e.margin.riskEngine.isLiquidatable(p.account));
        e.margin.liquidator.liquidate(_liquidation(id));
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.LIQUIDATED));
        assertEq(PToken(p.debtPToken).borrowBalanceStored(p.account), 0);
        assertEq(e.margin.vault.lockedBalance(USER, address(e.lending.pUsdc)), 0);
    }

    function _activate(uint16 leverage) private {
        IsolatedMarginTypes.PairRiskConfig memory r = IsolatedMarginTypes.PairRiskConfig(
            true,
            leverage,
            leverage == 500 ? 2000 : 5000,
            leverage == 500 ? 1000 : 3500,
            12_500,
            5000,
            5000,
            500,
            100,
            100,
            10_000e18,
            5000e18
        );
        address usd = address(e.lending.pUsdc);
        address avax = address(e.lending.pWavax);
        e.margin.config.queuePairRisk(usd, avax, usd, r);
        e.margin.config.queuePairRisk(usd, usd, avax, r);
        e.margin.config.queueUnpauseOpens();
        vm.warp(block.timestamp + e.margin.config.actionDelay());
        e.avaxFeed.setAnswer(10e8);
        e.usdFeed.setAnswer(1e8);
        e.margin.config.setPairRisk(usd, avax, usd, r);
        e.margin.config.setPairRisk(usd, usd, avax, r);
        e.adapter.setPaused(false);
        e.lender.setPaused(false);
        e.lending.controller._setBorrowPaused(PToken(usd), false);
        e.lending.controller._setBorrowPaused(PToken(avax), false);
        e.margin.config.unpauseOpens();
    }

    function _roundTrip(bool short, uint16 leverage) private {
        uint256 before = e.margin.vault.freeBalance(USER, address(e.lending.pUsdc));
        uint256 id = _open(short, leverage);
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.AccountMetrics memory m = e.margin.riskEngine.getMetrics(p.account);
        assertLe(m.leverageX100, leverage);
        assertGe(m.leverageX100, leverage - 1);
        assertGt(m.healthFactorBps, 10_000);
        (, uint256 cf,) = e.lending.controller.markets(p.positionPToken);
        assertEq(cf, 0);
        vm.prank(USER);
        e.margin.executor.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        assertEq(PToken(p.debtPToken).borrowBalanceStored(p.account), 0);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertApproxEqAbs(e.margin.vault.freeBalance(USER, address(e.lending.pUsdc)), before, 50_000);
    }

    function _open(bool short, uint16 leverage) private returns (uint256 id) {
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(short, leverage);
        vm.prank(USER);
        return e.margin.executor.openPosition(params);
    }

    function _params(bool short, uint16 leverage)
        private
        view
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory)
    {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(e.lending.pUsdc),
            short ? address(e.lending.pUsdc) : address(e.lending.pWavax),
            short ? address(e.lending.pWavax) : address(e.lending.pUsdc),
            MARGIN_SHARES,
            leverage,
            0,
            short ? uint256(leverage) * 1e6 * 999 / 1000 : uint256(leverage) * 1e17 * 99 / 100,
            short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
            ""
        );
    }

    function _position(uint256 id) private view returns (IsolatedMarginTypes.Position memory p) {
        (
            p.id,
            p.owner,
            p.account,
            p.marginPToken,
            p.positionPToken,
            p.debtPToken,
            p.lockedMarginPTokens,
            p.initialNotionalUsd,
            p.borrowedPrincipal,
            p.requestedLeverageX100,
            p.side,
            p.status
        ) = e.margin.executor.positions(id);
    }

    function _liquidation(uint256 id)
        private
        pure
        returns (IsolatedMarginLiquidatorUpgradeable.LiquidationParams memory)
    {
        return IsolatedMarginLiquidatorUpgradeable.LiquidationParams(id, address(0xBEEF), 0, 0, "", "");
    }
}
