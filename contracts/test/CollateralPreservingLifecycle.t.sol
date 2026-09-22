// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CollateralPreservingSettlementTest} from "./CollateralPreservingSettlement.t.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";

contract CollateralLifecycleInterestModel is InterestRateModel {
    uint256 public rate;

    function setRate(uint256 value) external {
        rate = value;
    }

    function getBorrowRate(uint256, uint256, uint256) external view override returns (uint256) {
        return rate;
    }

    function getSupplyRate(uint256, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Real local lending/flash/custody/risk/settlement; mock strategy, venue and prices.
/// Base fixture tests remain unchanged: new stack is enabled explicitly per new test.
contract CollateralPreservingLifecycleTest is CollateralPreservingSettlementTest {
    Risk internal engine;
    Executor internal executor;
    SimpleFlashLoanVault internal lender;

    function _enableStack() internal {
        engine = new Risk(address(this), address(settlement), 10_000, 10_000);
        IsolatedMarginAccountFactory f = new IsolatedMarginAccountFactory(address(this));
        executor = new Executor(address(engine), address(marginVault), address(f));
        f.setExecutor(address(executor));
        engine.setExecutor(address(executor));
        MarginInsuranceFundUpgradeable(INSURANCE).setLiquidator(address(executor));
        marginVault.setExecutor(address(executor));
        assertEq(controller._setIsolatedMarginRegistrar(address(engine)), 0);
        assertEq(controller._setIsolatedMarginRiskHook(address(engine)), 0);
        lender = SimpleFlashLoanVault(config.flashLoanProvider());
        lender.setFeeBps(0);
        lender.setTokenAllowed(address(usd), true);
        lender.setTokenAllowed(address(avax), true);
        usd.mint(address(lender), 100_000e6);
        avax.mint(address(lender), 100_000e18);
        usd.approve(address(pUsd), 100_000e6);
        avax.approve(address(pAvax), 100_000e18);
        assertEq(pUsd.mint(100_000e6), 0);
        assertEq(pAvax.mint(100_000e18), 0);
        config.queueUnpauseOpens();
        vm.warp(block.timestamp + 1 hours);
        config.unpauseOpens();
        _fundMargin(address(pUVault));
        _fundMargin(address(pAVault));
    }

    function _fundMargin(address collateral) internal {
        uint256 shares = quoter.feePToken(collateral, 300e18);
        IERC20(collateral).approve(address(marginVault), shares);
        marginVault.deposit(collateral, shares);
    }

    function _openLife(bool avaxCollateral, bool short, uint16 leverage) internal returns (uint256 id) {
        address collateral = avaxCollateral ? address(pAVault) : address(pUVault);
        Executor.OpenParams memory p;
        p.collateral = collateral;
        p.short = short;
        p.collateralShares = quoter.feePToken(collateral, 100e18);
        p.leverageX100 = leverage;
        p.maxFeeShares = type(uint256).max;
        p.deadline = block.timestamp;
        uint256 supplyBefore = IERC20(collateral).totalSupply();
        id = executor.openPosition(p);
        (, address account,,,,) = executor.positions(id);
        assertEq(IERC20(collateral).balanceOf(account), p.collateralShares, "opening redeemed original collateral");
        assertEq(IERC20(collateral).totalSupply(), supplyBefore);
        Risk.Snapshot memory s = engine.snapshot(account, 0);
        assertFalse(s.metrics.liquidatable);
        assertLe(s.metrics.tradingLeverageX100, leverage);
        assertGt(s.metrics.tradingLeverageX100, leverage * 90 / 100);
        assertGt(s.metrics.healthFactorBps, 15_000);
    }

    function _closeLife(uint256 id, uint16 fraction) internal {
        Executor.CloseParams memory p = _closeParams(id, fraction);
        executor.closePosition(p);
    }

    function _closeParams(uint256 id, uint16 fraction) internal view returns (Executor.CloseParams memory p) {
        p.id = id;
        p.fractionBps = fraction;
        p.maxFeeShares = type(uint256).max;
        p.maxCollateralSharesToSell = type(uint256).max;
        p.deadline = block.timestamp;
    }

    function testLifecycleBothCollateralTypesLongShortTwoThroughFiveX() public {
        _enableStack();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                for (uint16 leverage = 200; leverage <= 500; leverage += 100) {
                    uint256 id = _openLife(c == 1, side == 1, leverage);
                    (, address account, address collateral, address position, address debt,) = executor.positions(id);
                    _closeLife(id, 10_000);
                    assertEq(PErc20(debt).borrowBalanceStored(account), 0);
                    assertEq(IERC20(position).balanceOf(account), 0);
                    assertEq(IERC20(collateral).balanceOf(account), 0);
                    assertEq(marginVault.lockedBalance(address(this), collateral), 0);
                    (,,, Types.Status status,) = engine.accounts(account);
                    assertEq(uint256(status), uint256(Types.Status.CLOSED));
                    _executorClean();
                }
            }
        }
    }

    function testLifecyclePartialCloseThenFullPreservesRemainingCollateral() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt, uint256 lockedBefore) = executor.positions(id);
        uint256 debtBefore = PErc20(debt).borrowBalanceStored(account);
        _closeLife(id, 5000);
        assertApproxEqAbs(PErc20(debt).borrowBalanceStored(account), debtBefore / 2, 2);
        assertEq(IERC20(collateral).balanceOf(account), lockedBefore);
        assertEq(marginVault.lockedBalance(address(this), collateral), lockedBefore);
        _closeLife(id, 10_000);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        _executorClean();
    }

    function testLifecycleNoCollateralConsumedEvenWhenStrategyRedemptionClosedOnOpen() public {
        _enableStack();
        uVault.setLimits(true, true);
        aVault.setLimits(true, true);
        uint256 id = _openLife(false, false, 500);
        uVault.setLimits(true, false);
        _closeLife(id, 10_000);
        id = _openLife(true, true, 500);
        aVault.setLimits(true, false);
        _closeLife(id, 10_000);
    }

    function testLifecycleUnsolicitedFlashCallbackRejected() public {
        _enableStack();
        vm.expectRevert(Executor.InvalidCallback.selector);
        executor.onFlashLoan(address(executor), address(usd), 1e6, 0, "");
    }

    function testLifecycleProfitsWithClosedPharaohDepositsBothCollateralTypesAndSides() public {
        _enableStack();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                _price(10e8);
                uint256 id = _openLife(c == 1, side == 1, 500);
                (, address account, address collateral,,,) = executor.positions(id);
                uint256 original = IERC20(collateral).balanceOf(account);
                uint256 freeBefore = marginVault.freeBalance(address(this), collateral);
                uint256 usdBefore = usd.balanceOf(address(this));
                _price(side == 1 ? 9e8 : 11e8);
                uVault.setLimits(true, true);
                aVault.setLimits(true, true);
                _closeLife(id, 10_000);
                assertGt(usd.balanceOf(address(this)), usdBefore);
                assertEq(marginVault.freeBalance(address(this), collateral), freeBefore + original);
                _executorClean();
            }
        }
    }

    function testLifecycleLossAndPartialRewardWeightReconciliation() public {
        _enableStack();
        uint256 id = _openLife(true, false, 500);
        (, address account, address collateral,,,) = executor.positions(id);
        uint256 beforeShares = IERC20(collateral).balanceOf(account);
        _price(95e7);
        _closeLife(id, 5000);
        uint256 remaining = IERC20(collateral).balanceOf(account);
        assertLt(remaining, beforeShares);
        assertEq(marginVault.lockedBalance(address(this), collateral), remaining);
        (uint256 eligible,,) = fees.userRewards(collateral, address(this));
        assertEq(eligible, marginVault.freeBalance(address(this), collateral) + remaining);
        _closeLife(id, 10_000);
        assertEq(marginVault.lockedBalance(address(this), collateral), 0);
        _executorClean();
    }

    function testLifecycleActualInterestAndFlashFeesClearDebt() public {
        _enableStack();
        lender.setFeeBps(5);
        CollateralLifecycleInterestModel model = new CollateralLifecycleInterestModel();
        model.setRate(1e12);
        assertEq(pUsd._setInterestRateModel(model), 0);
        uint256 id = _openLife(false, false, 500);
        (, address account,,, address debt,) = executor.positions(id);
        uint256 beforeDebt = PErc20(debt).borrowBalanceStored(account);
        vm.roll(block.number + 10_000);
        PErc20(debt).accrueInterest();
        assertGt(PErc20(debt).borrowBalanceStored(account), beforeDebt);
        _closeLife(id, 10_000);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(PErc20(debt).totalBorrowShares(), 0);
        assertEq(PErc20(debt).totalBorrows(), 0);
        _executorClean();
    }

    function testLifecycleHealthyPositionsCannotBeLiquidated() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        Executor.CloseParams memory p = _closeParams(id, 5000);
        vm.expectRevert(Risk.UnsafePosition.selector);
        executor.liquidate(p, 0);
    }

    function testLifecyclePartialLiquidationLongAndShortImprovesHealth() public {
        _enableStack();
        for (uint256 scenario; scenario < 4; ++scenario) {
            uint256 side = scenario % 2;
            bool avaxCollateral = scenario >= 2;
            _price(10e8);
            uint256 id = _openLife(avaxCollateral, side == 1, 500);
            (, address account,,,,) = executor.positions(id);
            _price(avaxCollateral ? (side == 1 ? 116e7 : 88e7) : (side == 1 ? 113e7 : 87e7));
            Risk.Snapshot memory beforeState = engine.snapshot(account, 0);
            assertTrue(beforeState.metrics.liquidatable);
            Executor.CloseParams memory p = _closeParams(id, 5000);
            address keeper = address(0xBEEF);
            vm.prank(keeper);
            executor.liquidate(p, 0);
            assertGt(IERC20(avaxCollateral ? address(pAVault) : address(pUVault)).balanceOf(keeper), 0);
            assertGt(engine.snapshot(account, 0).metrics.healthFactorBps, beforeState.metrics.healthFactorBps);
            _price(10e8);
            _closeLife(id, 10_000);
            _executorClean();
        }
    }

    function testLifecycleFullInsolventLiquidationUsesInsuranceAfterCollateral() public {
        _enableStack();
        usd.mint(INSURANCE, 1000e6);
        avax.mint(INSURANCE, 1000e18);
        for (uint256 scenario; scenario < 4; ++scenario) {
            uint256 side = scenario % 2;
            _price(10e8);
            uint256 id = _openLife(scenario >= 2, side == 1, 500);
            (, address account, address collateral,, address debt,) = executor.positions(id);
            _price(side == 1 ? 20e8 : 5e8);
            assertLt(engine.snapshot(account, 0).metrics.equityUsd, 0);
            address debtAsset = PErc20(debt).underlying();
            uint256 insuranceBefore = IERC20(debtAsset).balanceOf(INSURANCE);
            uint256 freeBefore = marginVault.freeBalance(address(this), collateral);
            Executor.CloseParams memory p = _closeParams(id, 10_000);
            vm.prank(address(0xBEEF));
            executor.liquidate(p, side == 1 ? 100e18 : 1000e6);
            assertLt(IERC20(debtAsset).balanceOf(INSURANCE), insuranceBefore);
            uint256 budget = side == 1 ? 100e18 : 1000e6;
            assertGt(IERC20(debtAsset).balanceOf(INSURANCE), insuranceBefore > budget ? insuranceBefore - budget : 0);
            assertEq(PErc20(debt).borrowBalanceStored(account), 0);
            assertEq(marginVault.lockedBalance(address(this), collateral), 0);
            assertEq(marginVault.freeBalance(address(this), collateral), freeBefore);
            (,,, Types.Status status,) = engine.accounts(account);
            assertEq(uint256(status), uint256(Types.Status.LIQUIDATED));
            _executorClean();
        }
    }

    function testLifecycleInsufficientInsuranceRevertsAllLiquidationEffects() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt,) = executor.positions(id);
        _price(5e8);
        uint256 sharesBefore = IERC20(collateral).balanceOf(account);
        uint256 debtBefore = PErc20(debt).borrowBalanceStored(account);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        vm.expectRevert();
        executor.liquidate(p, 1000e6);
        assertEq(IERC20(collateral).balanceOf(account), sharesBefore);
        assertEq(PErc20(debt).borrowBalanceStored(account), debtBefore);
        (,,, Types.Status status,) = engine.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.ACTIVE));
    }

    function testLifecycleOnlyOwnerCanCloseOrAddCollateral() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        vm.prank(address(0xBAD));
        vm.expectRevert(Executor.Unauthorized.selector);
        executor.closePosition(p);
        vm.prank(address(0xBAD));
        vm.expectRevert(Executor.Unauthorized.selector);
        executor.addCollateral(id, 1);
    }

    function testLifecycleFeesStayInEachOriginalCollateralPool() public {
        _enableStack();
        config.queueFees(10, 10, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        config.setFees(10, 10, 5000, 5000, 0);
        for (uint256 c; c < 2; ++c) {
            address collateral = c == 1 ? address(pAVault) : address(pUVault);
            address other = c == 1 ? address(pUVault) : address(pAVault);
            uint256 otherInsuranceBefore = IERC20(other).balanceOf(INSURANCE);
            uint256 insuranceBefore = IERC20(collateral).balanceOf(INSURANCE);
            uint256 id = _openLife(c == 1, c == 1, 500);
            uint256 afterOpen = IERC20(collateral).balanceOf(INSURANCE);
            assertGt(afterOpen, insuranceBefore);
            _closeLife(id, 10_000);
            assertGt(IERC20(collateral).balanceOf(INSURANCE), afterOpen);
            assertEq(IERC20(other).balanceOf(INSURANCE), otherInsuranceBefore);
            _executorClean();
        }
    }

    function testLifecycleDisabledPairAndPausedBorrowingStillAllowClose() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        config.disablePair(address(pUVault), address(pAvax), address(pUsd));
        config.pauseOpens();
        controller._setBorrowPaused(PToken(address(pUsd)), true);
        _closeLife(id, 10_000);
        _executorClean();
    }

    function testLifecycleStalePriceRevertsBeforeCollateralMoves() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,,, uint256 locked) = executor.positions(id);
        vm.warp(block.timestamp + 31 days);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        vm.expectRevert();
        executor.closePosition(p);
        assertEq(IERC20(collateral).balanceOf(account), locked);
        assertEq(marginVault.lockedBalance(address(this), collateral), locked);
        _price(10e8);
        _closeLife(id, 10_000);
    }

    function testLifecycleInsufficientFlashLiquidityPreventsOpenWithoutMovingCollateral() public {
        _enableStack();
        lender.setPaused(true);
        uint256 free = marginVault.freeBalance(address(this), address(pUVault));
        Executor.OpenParams memory p;
        p.collateral = address(pUVault);
        p.collateralShares = quoter.feePToken(address(pUVault), 100e18);
        p.leverageX100 = 500;
        p.deadline = block.timestamp;
        vm.expectRevert(Risk.UnsafePosition.selector);
        executor.openPosition(p);
        assertEq(marginVault.freeBalance(address(this), address(pUVault)), free);
        assertEq(executor.nextPositionId(), 1);
    }

    function testLifecycleCollateralNavLossChangesHealthWithoutTradingPriceMove() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account,,,,) = executor.positions(id);
        Risk.Snapshot memory beforeState = engine.snapshot(account, 0);
        // Simulate a strategy loss independently of the $10 AVAX and $1 USDC feeds.
        uint256 loss = usd.balanceOf(address(uVault)) / 2;
        vm.prank(address(uVault));
        usd.transfer(address(0xDEAD), loss);
        Risk.Snapshot memory afterState = engine.snapshot(account, 0);
        assertLt(afterState.collateralUsd, beforeState.collateralUsd);
        assertEq(afterState.tradingUsd, beforeState.tradingUsd);
        assertEq(afterState.debtUsd, beforeState.debtUsd);
        assertLt(afterState.metrics.healthFactorBps, beforeState.metrics.healthFactorBps);
    }

    function testLifecycleActualFiveXRequestedLiquidationDistances() public {
        _enableStack();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                _price(10e8);
                uint256 id = _openLife(c == 1, side == 1, 500);
                (, address account,,,,) = executor.positions(id);
                uint256 low = side == 1 ? 10e8 : 5e8;
                uint256 high = side == 1 ? 20e8 : 10e8;
                while (high - low > 1) {
                    uint256 mid = (high + low) / 2;
                    _price(mid);
                    bool unhealthy = engine.snapshot(account, 0).metrics.liquidatable;
                    if (side == 1 ? unhealthy : !unhealthy) high = mid;
                    else low = mid;
                }
                uint256 distance = side == 1 ? (high - 10e8) * 10_000 / 10e8 : (10e8 - low) * 10_000 / 10e8;
                emit log_named_uint(c == 1 ? "AVAX collateral" : "USD collateral", side);
                emit log_named_uint("liquidation boundary AVAX price e8", side == 1 ? high : low);
                emit log_named_uint("adverse distance bps", distance);
                assertGt(distance, 800, "unexpectedly narrow entry-to-liquidation distance");
                _price(10e8);
                _closeLife(id, 10_000);
            }
        }
    }

    function testLifecycleFuzzOpenPartialFullRoundTrip(
        bool avaxCollateral,
        bool short,
        uint16 rawLeverage,
        uint16 rawFraction
    ) public {
        _enableStack();
        uint16 leverage = uint16(bound(uint256(rawLeverage), 200, 500));
        uint16 fraction = uint16(bound(uint256(rawFraction), 1000, 9000));
        uint256 id = _openLife(avaxCollateral, short, leverage);
        (, address account, address collateral,, address debt,) = executor.positions(id);
        _closeLife(id, fraction);
        assertGt(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(IERC20(collateral).balanceOf(account), marginVault.lockedBalance(address(this), collateral));
        _closeLife(id, 10_000);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(marginVault.lockedBalance(address(this), collateral), 0);
        _executorClean();
    }

    function testLifecycleAddCollateralImprovesHealthAndRewardShares() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,,,) = executor.positions(id);
        uint256 health = engine.snapshot(account, 0).metrics.healthFactorBps;
        uint256 amount = quoter.feePToken(collateral, 20e18);
        uint256 oldLocked = marginVault.lockedBalance(address(this), collateral);
        executor.addCollateral(id, amount);
        assertGt(engine.snapshot(account, 0).metrics.healthFactorBps, health);
        assertEq(IERC20(collateral).balanceOf(account), oldLocked + amount);
        assertEq(marginVault.lockedBalance(address(this), collateral), oldLocked + amount);
        _closeLife(id, 10_000);
    }

    function testLifecycleMissingFlashCallbackRollsBackOpeningAndLock() public {
        _enableStack();
        Executor.OpenParams memory p;
        p.collateral = address(pUVault);
        p.collateralShares = quoter.feePToken(address(pUVault), 100e18);
        p.leverageX100 = 500;
        p.deadline = block.timestamp;
        uint256 free = marginVault.freeBalance(address(this), address(pUVault));
        vm.mockCall(
            address(lender), abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)"), abi.encode(true)
        );
        vm.expectRevert(Executor.InvalidCallback.selector);
        executor.openPosition(p);
        assertEq(marginVault.freeBalance(address(this), address(pUVault)), free);
        assertEq(executor.nextPositionId(), 1);
    }

    function testLifecycleRiskHookRejectsForeignCallersAndOneTimeExecutorRebinding() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,,,) = executor.positions(id);
        vm.expectRevert(Risk.Unauthorized.selector);
        engine.transferAllowed(account, collateral, 1);
        vm.expectRevert(Risk.Unauthorized.selector);
        engine.authorize(account, collateral, 1);
        vm.expectRevert(Risk.InvalidConfiguration.selector);
        engine.setExecutor(address(this));
    }

    function testLifecycleChangedVaultAssetFailsClosedBeforeOpen() public {
        _enableStack();
        uint256 shares = quoter.feePToken(address(pUVault), 100e18);
        vm.mockCall(address(uVault), abi.encodeWithSignature("asset()"), abi.encode(address(avax)));
        vm.expectRevert(Risk.InvalidConfiguration.selector);
        engine.quoteOpen(address(pUVault), false, shares, 500);
    }

    function testLifecycleContractsFitEip170RuntimeLimit() public {
        _enableStack();
        assertLe(address(executor).code.length, 24_576);
        assertLe(address(engine).code.length, 24_576);
        assertLe(address(settlement).code.length, 24_576);
        assertLe(address(swapModule).code.length, 24_576);
    }

    function testLifecycleFeeAndLossLimitsRollbackOwnerClose() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt, uint256 locked) = executor.positions(id);
        uint256 debtBefore = PErc20(debt).borrowBalanceStored(account);
        _price(95e7);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        p.maxCollateralSharesToSell = 0;
        vm.expectRevert();
        executor.closePosition(p);
        assertEq(IERC20(collateral).balanceOf(account), locked);
        assertEq(PErc20(debt).borrowBalanceStored(account), debtBefore);
        config.queueFees(0, 10, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        config.setFees(0, 10, 5000, 5000, 0);
        p = _closeParams(id, 10_000);
        p.maxFeeShares = 0;
        vm.expectRevert(Executor.FeeLimit.selector);
        executor.closePosition(p);
        assertEq(IERC20(collateral).balanceOf(account), locked);
    }

    function testLifecycleFullLiquidationCannotBypassPartialCapOrSpendInsuranceOnPartial() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        _price(87e7);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        vm.expectRevert(Executor.InvalidOperation.selector);
        executor.liquidate(p, 0);
        p = _closeParams(id, 5000);
        vm.expectRevert(Executor.InvalidOperation.selector);
        executor.liquidate(p, 1000e6);
    }

    function _price(uint256 answer) internal {
        aFeed.setRound(int256(answer), block.timestamp, aFeed.roundId() + 1, aFeed.roundId() + 1);
        uFeed.setRound(1e8, block.timestamp, uFeed.roundId() + 1, uFeed.roundId() + 1);
        router.setPrice(answer / 100);
    }

    function _executorClean() internal view {
        address[4] memory tokens = [address(usd), address(avax), address(pUVault), address(pAVault)];
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(executor)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(executor), address(lender)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(executor), address(settlement)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(executor), address(swapModule)), 0);
        }
    }
}
