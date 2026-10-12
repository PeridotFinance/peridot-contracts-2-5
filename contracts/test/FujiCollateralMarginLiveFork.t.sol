// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";

/// @notice LOCAL-ONLY rehearsal on the actual deployed Fuji stack AFTER its 2x withdrawals.
/// No broadcasts, private keys, governance changes or real price manipulation.
/// The VM impersonates the mock feed owner solely inside an isolated local fork.
contract FujiCollateralMarginLiveForkTest is Test {
    uint256 constant FORK_BLOCK = 59_336_291;
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant TRADER = address(0xF031CAFE);
    address constant KEEPER = address(0xF031BEEF);
    Executor constant EXECUTOR = Executor(0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C);
    FujiMockPriceFeed constant USD_FEED = FujiMockPriceFeed(0xF7c5D63f1828699665b8f0Dfd8F28bBF0EA2c63d);
    FujiMockPriceFeed constant AVAX_FEED = FujiMockPriceFeed(0xD1BDAf98B5e2a73Ef2381e9767fEbF5b79ccbACb);
    Risk risk;
    address[2] collateral;

    function setUp() public {
        string memory rpc = vm.envOr("CP_FUJI_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        bool selected;
        try vm.activeFork() returns (uint256) {
            selected = true;
        } catch {}
        if (!selected) vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 43_113);
        assertEq(block.number, FORK_BLOCK);
        assertEq(EXECUTOR.nextPositionId(), 5);
        risk = EXECUTOR.risk();
        assertEq(risk.owner(), OWNER);
        assertEq(USD_FEED.owner(), OWNER);
        assertEq(AVAX_FEED.owner(), OWNER);
        collateral = [EXECUTOR.settlement().pUsdVault(), EXECUTOR.settlement().pAvaxVault()];
        _prices(10e8);
        _accrue();
        for (uint256 pool; pool < 2; ++pool) {
            // Transfer EXISTING mock pTokens locally; do not fabricate shares or change storage.
            uint256 budget = _budget(pool);
            vm.prank(OWNER);
            assertTrue(IERC20(collateral[pool]).transfer(TRADER, budget));
            vm.startPrank(TRADER);
            IERC20(collateral[pool]).approve(address(EXECUTOR.vault()), budget);
            EXECUTOR.vault().deposit(collateral[pool], budget);
            IERC20(collateral[pool]).approve(address(EXECUTOR.vault()), 0);
            vm.stopPrank();
        }
    }

    function testActualStackThreeThroughFiveXBothPoolsAndDirections() public {
        for (uint256 pool; pool < 2; ++pool) {
            for (uint256 side; side < 2; ++side) {
                for (uint16 leverage = 300; leverage <= 500; leverage += 100) {
                    uint256 checkpoint = vm.snapshotState();
                    (uint256 id, address account) = _open(pool, side == 1, leverage);
                    Risk.Snapshot memory entry = risk.snapshot(account, 0);
                    uint256 distance = _firstLiquidatableDistance(account, side == 1);
                    // Regression against near-entry liquidation; not a production risk endorsement.
                    assertGe(distance, 500, "liquidation distance below 5% at entry");
                    console2.log("collateral pool / short", pool, side);
                    console2.log("requested / actual leverage x100", leverage, entry.metrics.tradingLeverageX100);
                    console2.log("entry health / adverse distance bps", entry.metrics.healthFactorBps, distance);
                    console2.log("first liquidatable AVAX price, 8 decimals", _priceAtDistance(distance, side == 1));
                    _prices(10e8);
                    _close(id, pool);
                    _assertFinished(id, Types.Status.CLOSED);
                    uint256 remaining = EXECUTOR.vault().freeBalance(TRADER, collateral[pool]);
                    assertGe(remaining, _budget(pool) * 95 / 100);
                    uint256 wallet = IERC20(collateral[pool]).balanceOf(TRADER);
                    uint256 supply = PErc20(collateral[pool]).totalSupply();
                    vm.startPrank(TRADER);
                    EXECUTOR.vault().withdraw(collateral[pool], remaining);
                    vm.stopPrank();
                    assertEq(IERC20(collateral[pool]).balanceOf(TRADER), wallet + remaining);
                    assertEq(PErc20(collateral[pool]).totalSupply(), supply);
                    assertTrue(vm.revertToStateAndDelete(checkpoint));
                }
            }
        }
    }

    function testActualStackPartialLiquidationImprovesHealthAndClosesBothPoolsAndDirections() public {
        for (uint256 pool; pool < 2; ++pool) {
            for (uint256 side; side < 2; ++side) {
                uint256 checkpoint = vm.snapshotState();
                (uint256 id, address account) = _open(pool, side == 1, 500);
                uint256 bps = pool == 0 ? (side == 0 ? 8700 : 11_300) : (side == 0 ? 8800 : 11_600);
                _prices(10e8 * bps / 10_000);
                Risk.Snapshot memory beforeState = risk.snapshot(account, 0);
                assertTrue(beforeState.metrics.liquidatable);
                address debt = _debt(id);
                uint256 beforeDebt = PErc20(debt).borrowBalanceStored(account);
                Executor.CloseParams memory p = _liquidationParams(id, 5000);
                _setTradeMinimum(p, id);
                vm.prank(KEEPER);
                EXECUTOR.liquidate(p, 0);
                assertGt(risk.snapshot(account, 0).metrics.healthFactorBps, beforeState.metrics.healthFactorBps);
                assertLt(PErc20(debt).borrowBalanceStored(account), beforeDebt);
                assertGt(PErc20(debt).borrowBalanceStored(account), 0);
                _prices(10e8);
                _close(id, pool);
                _assertFinished(id, Types.Status.CLOSED);
                assertTrue(vm.revertToStateAndDelete(checkpoint));
            }
        }
    }

    function testActualStackInsuredFullLiquidationBothPoolsAndDirections() public {
        for (uint256 pool; pool < 2; ++pool) {
            for (uint256 side; side < 2; ++side) {
                uint256 checkpoint = vm.snapshotState();
                (uint256 id, address account) = _open(pool, side == 1, 500);
                _prices(side == 0 ? 5e8 : 20e8);
                assertLt(risk.snapshot(account, 0).metrics.equityUsd, 0);
                address asset = PErc20(_debt(id)).underlying();
                address insurance = EXECUTOR.config().insuranceFund();
                uint256 beforeInsurance = IERC20(asset).balanceOf(insurance);
                Executor.CloseParams memory p = _liquidationParams(id, 10_000);
                _setTradeMinimum(p, id);
                uint256 coverageCap = side == 0 ? 100e6 : 10e18;
                vm.prank(KEEPER);
                EXECUTOR.liquidate(p, coverageCap);
                uint256 used = beforeInsurance - IERC20(asset).balanceOf(insurance);
                assertGt(used, 0);
                assertLe(used, coverageCap);
                _assertFinished(id, Types.Status.LIQUIDATED);
                _prices(10e8);
                assertTrue(vm.revertToStateAndDelete(checkpoint));
            }
        }
    }

    function testUnprivilegedTraderCannotSetPricesOrLiquidateHealthyPosition() public {
        (uint256 id,) = _open(0, false, 500);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", TRADER));
        vm.prank(TRADER);
        AVAX_FEED.setAnswer(5e8);
        assertEq(AVAX_FEED.answer(), 10e8);
        Executor.CloseParams memory p = _liquidationParams(id, 5000);
        vm.expectRevert(Risk.UnsafePosition.selector);
        vm.prank(KEEPER);
        EXECUTOR.liquidate(p, 0);
        _close(id, 0);
        _assertFinished(id, Types.Status.CLOSED);
    }

    function testActualStackFiveXAfterOneDayInterestBothDirections() public {
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            (uint256 id, address account) = _open(0, side == 1, 500);
            uint256 beforeDebt = PErc20(_debt(id)).borrowBalanceStored(account);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.roll(block.number + 43_200);
            _prices(10e8);
            _accrue();
            assertGt(PErc20(_debt(id)).borrowBalanceStored(account), beforeDebt);
            assertFalse(risk.snapshot(account, 0).metrics.liquidatable);
            _close(id, 0);
            _assertFinished(id, Types.Status.CLOSED);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
        }
    }

    function _open(uint256 pool, bool short, uint16 leverage) private returns (uint256 id, address account) {
        Executor.OpenParams memory p;
        p.collateral = collateral[pool];
        p.short = short;
        p.collateralShares = _budget(pool) * 5 / 12; // $25 margin out of $60 pool budget.
        p.leverageX100 = leverage;
        p.maxFeeShares = _budget(pool) / 240; // $0.25 per action, finite up to 5x.
        (, p.minPositionOut) = risk.quoteOpen(p.collateral, short, p.collateralShares, leverage);
        p.deadline = block.timestamp + 1 hours;
        vm.prank(TRADER);
        id = EXECUTOR.openPosition(p);
        (, account,,,,) = EXECUTOR.positions(id);
        assertEq(IERC20(p.collateral).balanceOf(account), p.collateralShares);
        Risk.Snapshot memory entry = risk.snapshot(account, 0);
        assertFalse(entry.metrics.liquidatable);
        assertGt(entry.metrics.tradingLeverageX100, leverage * 90 / 100);
        assertLe(entry.metrics.tradingLeverageX100, leverage);
    }

    function _close(uint256 id, uint256 pool) private {
        Executor.CloseParams memory p = _liquidationParams(id, 10_000);
        p.maxFeeShares = _budget(pool) / 240;
        p.maxCollateralSharesToSell = _budget(pool) / 30; // $2 maximum voluntary close sale.
        _setTradeMinimum(p, id);
        vm.prank(TRADER);
        EXECUTOR.closePosition(p);
    }

    function _liquidationParams(uint256 id, uint16 fraction) private view returns (Executor.CloseParams memory p) {
        p.id = id;
        p.fractionBps = fraction;
        p.deadline = block.timestamp + 1 hours;
    }

    function _setTradeMinimum(Executor.CloseParams memory p, uint256 id) private view {
        (, address account,, address position, address debt,) = EXECUTOR.positions(id);
        uint256 shares = Math.mulDiv(IERC20(position).balanceOf(account), p.fractionBps, 10_000);
        uint256 underlying = Math.mulDiv(shares, PErc20(position).exchangeRateStored(), 1e18);
        p.minTradeDebtOut = EXECUTOR.quoter()
                .expectedOut(PErc20(position).underlying(), PErc20(debt).underlying(), underlying) * 99 / 100;
    }

    function _assertFinished(uint256 id, Types.Status expected) private view {
        (, address account, address c, address position, address debt, uint256 locked) = EXECUTOR.positions(id);
        (,,, Types.Status status,) = risk.accounts(account);
        assertEq(uint256(status), uint256(expected));
        assertEq(locked, 0);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(IERC20(c).balanceOf(account), 0);
        assertEq(IERC20(position).balanceOf(account), 0);
        assertEq(EXECUTOR.vault().lockedBalance(TRADER, c), 0);
        assertEq(IERC20(c).allowance(TRADER, address(EXECUTOR.vault())), 0);
        assertEq(PErc20(EXECUTOR.settlement().pUsd()).totalBorrows(), 0);
        assertEq(PErc20(EXECUTOR.settlement().pWavax()).totalBorrows(), 0);
    }

    function _firstLiquidatableDistance(address account, bool short) private returns (uint256) {
        uint256 low;
        uint256 high = 5000;
        _prices(_priceAtDistance(high, short));
        assertTrue(risk.snapshot(account, 0).metrics.liquidatable);
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            _prices(_priceAtDistance(mid, short));
            if (risk.snapshot(account, 0).metrics.liquidatable) high = mid;
            else low = mid;
        }
        _prices(_priceAtDistance(low, short));
        assertFalse(risk.snapshot(account, 0).metrics.liquidatable);
        _prices(_priceAtDistance(high, short));
        assertTrue(risk.snapshot(account, 0).metrics.liquidatable);
        return high;
    }

    function _priceAtDistance(uint256 bps, bool short) private pure returns (uint256) {
        return 10e8 * (short ? 10_000 + bps : 10_000 - bps) / 10_000;
    }

    function _prices(uint256 avaxPrice) private {
        vm.startPrank(OWNER);
        USD_FEED.setAnswer(1e8);
        AVAX_FEED.setAnswer(int256(avaxPrice));
        vm.stopPrank();
    }

    function _accrue() private {
        PErc20(EXECUTOR.settlement().pUsd()).exchangeRateCurrent();
        PErc20(EXECUTOR.settlement().pWavax()).exchangeRateCurrent();
        PErc20(collateral[0]).exchangeRateCurrent();
        PErc20(collateral[1]).exchangeRateCurrent();
    }

    function _debt(uint256 id) private view returns (address debt) {
        (,,,, debt,) = EXECUTOR.positions(id);
    }

    function _budget(uint256 pool) private pure returns (uint256) {
        return pool == 0 ? 3000e8 : 300e8;
    }
}
