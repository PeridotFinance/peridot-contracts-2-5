// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {PToken} from "../contracts/PToken.sol";
import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PharaohMarginOracle} from "../contracts/margin/PharaohMarginOracle.sol";
import {PharaohCLRouterAdapter, IPharaohCLRouter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
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
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";

/// @notice Whole LOCAL fork lifecycle: real Pharaoh strategies, CL venue, tokens,
/// feeds; fresh Peridot contracts and actual jump-rate/flash implementations.
/// Only local lending/flash balances are dealt, and a portion of existing Safe
/// vault shares is transferred by VM impersonation. No real pool/vault funding
/// or feed manipulation for round trips. Not proof of production-sized capacity.
contract PharaohCollateralMarginForkTest is Test {
    address constant USD = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant AVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant UV = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address constant AV = 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;
    address constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address constant UF = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address constant AF = 0x0A77230d17318075983913bC2145DB16C7366156;
    address constant ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    Peridottroller controller;
    ConfigurableJumpRateModelV2 irm;
    PErc20Delegator pUsd;
    PErc20Delegator pAvax;
    PErc20Delegator pUV;
    PErc20Delegator pAV;
    Config config;
    Fees fees;
    Insurance insurance;
    Vault vault;
    Quoter quoter;
    Swap swapModule;
    Settlement settlement;
    Risk risk;
    Executor executor;
    SimpleFlashLoanVault lender;
    PharaohCLRouterAdapter cl;
    PharaohMarginRouterAdapter adapter;

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Preserve the CLI backend's bounded RPC retry/timeout settings when the
        // runner already supplied the pinned fork. Avoid opening a second backend.
        bool selected;
        try vm.activeFork() returns (uint256) {
            selected = true;
        } catch {}
        if (!selected) vm.createSelectFork(rpc, 96_140_026);
        assertEq(block.chainid, 43_114);
        assertEq(block.number, 96_140_026);
        uint256 pinnedTime = vm.getBlockTimestamp();
        _markets();
        _execution();
        // Rehearse NEW local governance only, returning to original feed timestamp.
        vm.warp(pinnedTime - 1 hours);
        config.queueFeeRecipients(address(insurance), address(this));
        config.queueFees(10, 10, 5000, 5000, 0);
        config.queueUnpauseOpens();
        for (uint256 c; c < 2; ++c) {
            address collateral = c == 0 ? address(pUV) : address(pAV);
            config.queuePairRisk(collateral, address(pAvax), address(pUsd), _pair());
            config.queuePairRisk(collateral, address(pUsd), address(pAvax), _pair());
        }
        vm.warp(pinnedTime);
        config.setFeeRecipients(address(insurance), address(this));
        config.setFees(10, 10, 5000, 5000, 0);
        for (uint256 c; c < 2; ++c) {
            address collateral = c == 0 ? address(pUV) : address(pAV);
            config.setPairRisk(collateral, address(pAvax), address(pUsd), _pair());
            config.setPairRisk(collateral, address(pUsd), address(pAvax), _pair());
            uint256 shares = IERC20(collateral).balanceOf(address(this));
            IERC20(collateral).approve(address(vault), shares);
            vault.deposit(collateral, shares);
            IERC20(collateral).approve(address(vault), 0);
        }
        config.unpauseOpens();
        assertEq(IERC4626(UV).maxDeposit(address(this)), 0);
        assertEq(IERC4626(AV).maxDeposit(address(this)), 0);
    }

    function _markets() internal {
        Unitroller proxy = new Unitroller();
        Peridottroller implementation = new Peridottroller();
        assertEq(proxy._setPendingImplementation(address(implementation)), 0);
        implementation._become(proxy);
        controller = Peridottroller(address(proxy));
        // Test parameters, not approved production interest/risk settings.
        irm = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));
        address plain = address(new PErc20Delegate());
        address boosted = address(new PharaohBoostedDelegate());
        pUsd = _market(USD, plain, 2e14, "");
        pAvax = _market(AVAX, plain, 2e26, "");
        pUV = _market(UV, boosted, 2e14, abi.encode(UV, uint256(1)));
        pAV = _market(AV, boosted, 2e26, abi.encode(AV, uint256(1)));
        _seedShares(UV, pUV);
        _seedShares(AV, pAV);
        deal(USD, address(this), 10_000e6);
        deal(AVAX, address(this), 1000e18);
        IERC20(USD).approve(address(pUsd), 10_000e6);
        IERC20(AVAX).approve(address(pAvax), 1000e18);
        assertEq(pUsd.mint(10_000e6), 0);
        assertEq(pAvax.mint(1000e18), 0);
    }

    function _execution() internal {
        AvalanchePriceOracle base = new AvalanchePriceOracle(address(this));
        base.configureFeed(USD, UF, 90_000);
        base.configureFeed(AVAX, AF, 1200);
        base.registerMarket(address(pUsd), USD);
        base.registerMarket(address(pAvax), AVAX);
        PharaohVaultShareOracle shares = new PharaohVaultShareOracle(address(this), base);
        shares.registerVault(IERC4626(UV), AggregatorV3Interface(UF), 90_000);
        shares.registerVault(IERC4626(AV), AggregatorV3Interface(AF), 1200);
        assertEq(controller._setPriceOracle(shares), 0);
        PharaohMarginOracle oracle = new PharaohMarginOracle(base, shares, address(pUV), UV, address(pAV), AV);
        cl = new PharaohCLRouterAdapter(
            ROUTER,
            0xAE6E5c62328ade73ceefD42228528b70c8157D0d,
            0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534,
            AVAX,
            USD,
            10
        );
        adapter = new PharaohMarginRouterAdapter(UV, AV, USD, AVAX, address(cl));
        lender = new SimpleFlashLoanVault(address(this));
        lender.setFeeBps(5);
        lender.setTokenAllowed(USD, true);
        lender.setTokenAllowed(AVAX, true);
        deal(USD, address(lender), 10_000e6);
        deal(AVAX, address(lender), 1000e18);
        insurance = Insurance(_proxy(address(new Insurance()), abi.encodeCall(Insurance.initialize, (address(this)))));
        config = Config(
            _proxy(
                address(new Config()),
                abi.encodeCall(
                    Config.initialize,
                    (address(this), 1 hours, address(adapter), address(lender), address(insurance), address(this))
                )
            )
        );
        fees = Fees(_proxy(address(new Fees()), abi.encodeCall(Fees.initialize, (address(this), address(config)))));
        vault = Vault(_proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(this), address(fees)))));
        fees.setVault(address(vault));
        fees.setFeeCollector(address(vault), true);
        vault.setPTokenAllowed(address(pUV), true);
        vault.setPTokenAllowed(address(pAV), true);
        quoter = new Quoter(address(config), address(oracle));
        swapModule = new Swap(address(config), address(quoter));
        settlement = new Settlement(
            address(config),
            address(quoter),
            address(swapModule),
            address(fees),
            Settlement.Markets(USD, AVAX, address(pUsd), address(pAvax), address(pUV), address(pAV))
        );
        fees.setFeeCollector(address(settlement), true);
        risk = new Risk(address(this), address(settlement), 10_000, 10_000);
        Factory factory = new Factory(address(this));
        executor = new Executor(address(risk), address(vault), address(factory));
        factory.setExecutor(address(executor));
        risk.setExecutor(address(executor));
        insurance.setLiquidator(address(executor));
        vault.setExecutor(address(executor));
        assertEq(controller._setIsolatedMarginRegistrar(address(risk)), 0);
        assertEq(controller._setIsolatedMarginRiskHook(address(risk)), 0);
    }

    function _market(address asset, address impl, uint256 rate, bytes memory data)
        internal
        returns (PErc20Delegator p)
    {
        p = new PErc20Delegator(
            asset, controller, irm, rate, "Fork-only market", "pFORK", 8, payable(address(this)), impl, data
        );
        assertEq(controller._supportMarket(PToken(address(p))), 0);
    }

    function _seedShares(address underlying, PErc20Delegator p) internal {
        uint256 n = IERC20(underlying).balanceOf(SAFE) / 2;
        assertGt(n, 0);
        vm.prank(SAFE);
        assertTrue(IERC20(underlying).transfer(address(this), n));
        IERC20(underlying).approve(address(p), n);
        assertEq(p.mint(n), 0);
    }

    function _proxy(address implementation, bytes memory data) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, address(this), data));
    }

    function _pair() internal pure returns (Types.PairRiskConfig memory) {
        return Types.PairRiskConfig(true, 500, 2000, 1000, 12_500, 5000, 5000, 500, 100, 100, 1000e18, 1000e18);
    }

    function _open(bool avaxCollateral, bool short, uint16 leverage) internal returns (uint256 id) {
        address collateral = avaxCollateral ? address(pAV) : address(pUV);
        Executor.OpenParams memory p;
        p.collateral = collateral;
        p.short = short;
        p.collateralShares = quoter.feePToken(collateral, 1e18); // $1 from actual small seed shares
        p.leverageX100 = leverage;
        p.maxFeeShares = type(uint256).max;
        p.deadline = block.timestamp;
        uint256 supply = IERC20(collateral).totalSupply();
        id = executor.openPosition(p);
        (, address account,,,,) = executor.positions(id);
        assertEq(IERC20(collateral).balanceOf(account), p.collateralShares);
        assertEq(IERC20(collateral).totalSupply(), supply);
        Risk.Snapshot memory s = risk.snapshot(account, 0);
        assertFalse(s.metrics.liquidatable);
        assertLe(s.metrics.tradingLeverageX100, leverage);
        assertGt(s.metrics.tradingLeverageX100, leverage * 90 / 100);
        assertGt(s.metrics.healthFactorBps, 15_000);
    }

    function _close(uint256 id, uint16 fraction) internal {
        executor.closePosition(_closeParams(id, fraction));
    }

    function _closeParams(uint256 id, uint16 fraction) internal view returns (Executor.CloseParams memory p) {
        p.id = id;
        p.fractionBps = fraction;
        p.maxFeeShares = type(uint256).max;
        p.maxCollateralSharesToSell = type(uint256).max;
        p.deadline = block.timestamp;
    }

    function _assertClosed(uint256 id) internal view {
        (, address account, address collateral, address position, address debt,) = executor.positions(id);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(PErc20(debt).totalBorrowShares(), 0);
        assertEq(IERC20(position).balanceOf(account), 0);
        assertEq(IERC20(collateral).balanceOf(account), 0);
        assertEq(vault.lockedBalance(address(this), collateral), 0);
        address[2] memory tokens = [USD, AVAX];
        for (uint256 i; i < 2; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(cl)), 0);
            assertEq(IERC20(tokens[i]).balanceOf(address(adapter)), 0);
            assertEq(IERC20(tokens[i]).balanceOf(address(executor)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(cl), ROUTER), 0);
        }
    }

    function _roundTrips(bool avaxCollateral, bool short) internal {
        for (uint16 lev = 200; lev <= 500; lev += 100) {
            uint256 id = _open(avaxCollateral, short, lev);
            _close(id, 10_000);
            _assertClosed(id);
        }
    }

    function testRealPharaohUsdLongTwoThroughFiveX() public {
        _roundTrips(false, false);
    }

    function testRealPharaohUsdShortTwoThroughFiveX() public {
        _roundTrips(false, true);
    }

    function testRealPharaohAvaxLongTwoThroughFiveX() public {
        _roundTrips(true, false);
    }

    function testRealPharaohAvaxShortTwoThroughFiveX() public {
        _roundTrips(true, true);
    }

    function testRealPharaohSingleFiveXUsdLongRoundTrip() public {
        uint256 id = _open(false, false, 500);
        _close(id, 10_000);
        _assertClosed(id);
    }

    function testRealPharaohPartialCloseThenWithdrawOriginalPTokens() public {
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                uint256 id = _open(c == 1, side == 1, 500);
                _close(id, 5000);
                _close(id, 10_000);
                _assertClosed(id);
            }
        }
        address[2] memory collaterals = [address(pUV), address(pAV)];
        for (uint256 c; c < 2; ++c) {
            uint256 n = vault.freeBalance(address(this), collaterals[c]);
            uint256 before = IERC20(collaterals[c]).balanceOf(address(this));
            vault.withdraw(collaterals[c], n);
            assertEq(IERC20(collaterals[c]).balanceOf(address(this)), before + n);
        }
    }

    function testRealPharaohStalePricesFailBeforeMovingCollateral() public {
        uint256 id = _open(false, false, 500);
        (, address account, address collateral,, address debt,) = executor.positions(id);
        uint256 shares = IERC20(collateral).balanceOf(account);
        uint256 borrowed = PErc20(debt).borrowBalanceStored(account);
        vm.warp(vm.getBlockTimestamp() + 1201);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        vm.expectRevert();
        executor.closePosition(p);
        assertEq(IERC20(collateral).balanceOf(account), shares);
        assertEq(PErc20(debt).borrowBalanceStored(account), borrowed);
    }

    /// @dev Synthetic stress on real pool/strategy execution, NOT historical price
    /// evidence. Move actual CL price via a locally funded swap, and mock only the
    /// Chainlink AVAX answer to reflect the same move. Restore fork per scenario.
    function testRealPharaohPartialLiquidationUnderSyntheticPriceShocks() public {
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                uint256 checkpoint = vm.snapshotState();
                uint256 id = _open(c == 1, side == 1, 500);
                (, address account, address collateral,,,) = executor.positions(id);
                _shock(c == 0 ? (side == 0 ? 8700 : 11300) : (side == 0 ? 8800 : 11600));
                Risk.Snapshot memory beforeState = risk.snapshot(account, 0);
                assertTrue(beforeState.metrics.liquidatable);
                Executor.CloseParams memory p = _closeParams(id, 5000);
                vm.prank(address(0xBEEF));
                executor.liquidate(p, 0);
                assertGt(risk.snapshot(account, 0).metrics.healthFactorBps, beforeState.metrics.healthFactorBps);
                assertGt(IERC20(collateral).balanceOf(address(0xBEEF)), 0);
                _close(id, 10_000);
                _assertClosed(id);
                vm.clearMockedCalls();
                assertTrue(vm.revertToState(checkpoint));
            }
        }
    }

    function testRealPharaohInsolventLiquidationUnderSyntheticPriceShocks() public {
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                uint256 checkpoint = vm.snapshotState();
                uint256 id = _open(c == 1, side == 1, 500);
                (, address account, address collateral,, address debt,) = executor.positions(id);
                _shock(side == 0 ? 5000 : 20000);
                assertLt(risk.snapshot(account, 0).metrics.equityUsd, 0);
                address debtAsset = PErc20(debt).underlying();
                uint256 budget = side == 0 ? 10e6 : 1e18;
                deal(debtAsset, address(insurance), budget);
                uint256 freeBefore = vault.freeBalance(address(this), collateral);
                // Releasing a position also claims already-earned opening-fee
                // rewards. Those are not collateral returned by liquidation.
                uint256 earnedBefore = fees.pendingRewards(address(this), collateral);
                Executor.CloseParams memory p = _closeParams(id, 10_000);
                vm.prank(address(0xBEEF));
                executor.liquidate(p, budget);
                assertLt(IERC20(debtAsset).balanceOf(address(insurance)), budget);
                assertGt(IERC20(debtAsset).balanceOf(address(insurance)), 0);
                assertEq(vault.freeBalance(address(this), collateral), freeBefore + earnedBefore);
                _assertClosed(id);
                vm.clearMockedCalls();
                assertTrue(vm.revertToState(checkpoint));
            }
        }
    }

    function _shock(uint256 priceBps) internal {
        address pool = cl.pool();
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(ok);
        uint160 current = abi.decode(data, (uint160));
        uint160 target = uint160(Math.mulDiv(current, Math.sqrt(priceBps * 1e32 / 10_000), 1e16));
        address trader = address(0xCAFE);
        address input = priceBps < 10_000 ? AVAX : USD;
        address output = priceBps < 10_000 ? USD : AVAX;
        uint256 amount = priceBps < 10_000 ? 100_000_000e18 : 1_000_000_000e6;
        deal(input, trader, amount); // LOCAL synthetic price pressure, not mainnet liquidity
        vm.startPrank(trader);
        IERC20(input).approve(ROUTER, amount);
        IPharaohCLRouter(ROUTER)
            .exactInputSingle(
                IPharaohCLRouter.ExactInputSingleParams(input, output, 10, trader, block.timestamp, amount, 1, target)
            );
        IERC20(input).approve(ROUTER, 0);
        vm.stopPrank();
        (ok, data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint160)), target, "stress failed to reach target price");
        (uint80 roundId, int256 answer,,, uint80 answered) = AggregatorV3Interface(AF).latestRoundData();
        vm.mockCall(
            AF,
            abi.encodeCall(AggregatorV3Interface.latestRoundData, ()),
            abi.encode(roundId, answer * int256(priceBps) / 10_000, block.timestamp, block.timestamp, answered)
        );
    }
}
