// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {IsolatedMarginExecutorUpgradeable as Executor} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {
    IsolatedMarginLiquidatorUpgradeable as Liquidator
} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable as Risk} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable as Vault} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable as Fees} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable as Insurance} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";
import {IsolatedMarginTypes as T} from "../contracts/margin/IsolatedMarginTypes.sol";

/// @notice LOCAL FORK ONLY. Uses deployed post-migration code, no implementation substitution.
/// Governance changes, account impersonation, price shocks and time advances never touch live Fuji.
contract FujiMarginProductionStressForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant KEEPER = address(0xBEEF);
    uint256 constant MARGIN = 5000e8;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    Executor constant EX = Executor(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    Liquidator constant LIQ = Liquidator(0xb344A644Dcf2176f50292ABDD6acDfdfea3F525d);
    Risk constant RISK = Risk(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);
    Config constant CONFIG = Config(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    Vault constant VAULT = Vault(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);
    Fees constant FEES = Fees(0x74ce8DAb244831F01700838e72ddFdDeAA19DF98);
    Insurance constant INS = Insurance(0xbD6f340277235483c881E79205E76bb62A9A548C);
    FujiMockSwapAdapter constant VENUE = FujiMockSwapAdapter(0xEF3F12c9D60bc86484dac6250BCC25d784Ba200B);

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_511_100);
        assertEq(block.chainid, 43_113);
        assertEq(EX.nextPositionId(), 7);
        assertTrue(USD.borrowAccountingEnabled() && AVAX.borrowAccountingEnabled());
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        _price(10e8);
        _fund(ALICE, MARGIN * 10);
    }

    function testLongSurvivesRepeatedAccrualAndPartialThenFullClose() public {
        _accrual(false);
    }

    function testShortSurvivesRepeatedAccrualAndPartialThenFullClose() public {
        _accrual(true);
    }

    function _accrual(bool short) private {
        uint256 id = _open(ALICE, short);
        PErc20 debt = short ? AVAX : USD;
        uint256 beforeDebt = debt.borrowBalanceStored(_account(id));
        uint256 beforeRate = debt.exchangeRateStored();
        uint256 beforeHealth = RISK.getMetrics(_account(id)).healthFactorBps;
        for (uint256 i; i < 64; ++i) {
            vm.roll(vm.getBlockNumber() + 10_000);
            vm.warp(vm.getBlockTimestamp() + 10_000);
            _price(10e8);
            USD.accrueInterest();
            AVAX.accrueInterest();
        }
        uint256 accrued = debt.borrowBalanceStored(_account(id));
        assertGt(accrued, beforeDebt);
        assertGt(debt.exchangeRateStored(), beforeRate);
        assertLt(RISK.getMetrics(_account(id)).healthFactorBps, beforeHealth);
        assertEq(VAULT.lockedBalance(ALICE, address(USD)), MARGIN);
        assertEq(debt.totalBorrows(), accrued);
        _close(ALICE, id, 5000);
        assertEq(uint256(_status(id)), uint256(T.Status.ACTIVE));
        assertLt(debt.borrowBalanceStored(_account(id)), accrued);
        _close(ALICE, id, 10_000);
        _noDebt();
        _withdraw(ALICE);
    }

    function testTwoBorrowersClosingOneDoesNotEraseOtherDebt() public {
        _fund(BOB, MARGIN * 10);
        uint256 a = _open(ALICE, false);
        uint256 b = _open(BOB, false);
        for (uint256 i; i < 64; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            USD.accrueInterest();
        }
        uint256 bobDebt = USD.borrowBalanceStored(_account(b));
        _close(ALICE, a, 10_000);
        assertEq(USD.borrowBalanceStored(_account(b)), bobDebt);
        assertEq(USD.totalBorrows(), bobDebt);
        assertGt(USD.totalBorrowShares(), 0);
        _close(BOB, b, 10_000);
        _noDebt();
    }

    function testLongPartialLiquidationImprovesHealthThenCloses() public {
        _partial(false, 8.7e8);
    }

    function testShortPartialLiquidationImprovesHealthThenCloses() public {
        _partial(true, 11.5e8);
    }

    function _partial(bool short, int256 price) private {
        uint256 id = _open(ALICE, short);
        _price(price);
        address account = _account(id);
        assertTrue(RISK.isLiquidatable(account));
        uint256 before = RISK.getMetrics(account).healthFactorBps;
        uint256 insuranceUsd = USD.balanceOf(address(INS));
        uint256 insuranceAvax = AVAX.balanceOf(address(INS));
        LIQ.liquidate(_liq(id));
        assertEq(uint256(_status(id)), uint256(T.Status.ACTIVE));
        assertGt(RISK.getMetrics(account).healthFactorBps, before);
        assertEq(USD.balanceOf(address(INS)), insuranceUsd);
        assertEq(AVAX.balanceOf(address(INS)), insuranceAvax);
        _price(10e8);
        _close(ALICE, id, 10_000);
        _noDebt();
    }

    function testLongCrashUsesInsuranceAndClearsDebt() public {
        _crash(false, 7.5e8);
    }

    function testShortSqueezeUsesInsuranceAndClearsDebt() public {
        _crash(true, 15e8);
    }

    function _crash(bool short, int256 price) private {
        uint256 id = _open(ALICE, short);
        uint256 before = USD.balanceOf(address(INS)) + AVAX.balanceOf(address(INS));
        _price(price);
        assertTrue(RISK.isLiquidatable(_account(id)));
        LIQ.liquidate(_liq(id));
        assertEq(uint256(_status(id)), uint256(T.Status.LIQUIDATED));
        assertLt(USD.balanceOf(address(INS)) + AVAX.balanceOf(address(INS)), before);
        assertEq(VAULT.lockedBalance(ALICE, address(USD)), 0);
        _noDebt();
    }

    function testEmptyInsuranceFailsClosedWithoutErasingBadDebt() public {
        uint256 id = _open(ALICE, true);
        vm.startPrank(OWNER);
        INS.recoverUnsupportedToken(address(USD), OWNER, USD.balanceOf(address(INS)));
        INS.recoverUnsupportedToken(address(AVAX), OWNER, AVAX.balanceOf(address(INS)));
        vm.stopPrank();
        _price(15e8);
        uint256 debt = AVAX.borrowBalanceStored(_account(id));
        uint256 collateral = USD.balanceOf(_account(id));
        Liquidator.LiquidationParams memory params = _liq(id);
        vm.expectRevert();
        LIQ.liquidate(params);
        assertEq(uint256(_status(id)), uint256(T.Status.ACTIVE));
        assertEq(AVAX.borrowBalanceStored(_account(id)), debt);
        assertEq(AVAX.totalBorrows(), debt);
        assertEq(USD.balanceOf(_account(id)), collateral);
        assertEq(VAULT.lockedBalance(ALICE, address(USD)), MARGIN);
    }

    function testStalePricesBlockDebtCloseWithoutLosingState() public {
        uint256 id = _open(ALICE, false);
        uint256 debt = USD.borrowBalanceStored(_account(id));
        vm.warp(vm.getBlockTimestamp() + 1201);
        Executor.CloseParams memory params = _closeParams(id, 10_000);
        vm.prank(ALICE);
        vm.expectRevert();
        EX.closePosition(params);
        assertEq(USD.borrowBalanceStored(_account(id)), debt);
        assertEq(uint256(_status(id)), uint256(T.Status.ACTIVE));
        _price(10e8);
        _close(ALICE, id, 10_000);
        _noDebt();
    }

    function testExcessExitSlippageRevertsWithoutDebtOrCollateralLoss() public {
        uint256 id = _open(ALICE, false);
        uint256 debt = USD.borrowBalanceStored(_account(id));
        uint256 collateral = AVAX.balanceOf(_account(id));
        vm.prank(OWNER);
        VENUE.setExecutionBps(9800);
        Executor.CloseParams memory params = _closeParams(id, 10_000);
        vm.prank(ALICE);
        vm.expectRevert();
        EX.closePosition(params);
        assertEq(USD.borrowBalanceStored(_account(id)), debt);
        assertEq(AVAX.balanceOf(_account(id)), collateral);
        vm.prank(OWNER);
        VENUE.setExecutionBps(10_000);
        _close(ALICE, id, 10_000);
        _noDebt();
    }

    function testFeesSplitAndStreamAcrossFreeAndLockedDepositors() public {
        _fees();
        _fund(BOB, MARGIN * 10);
        uint256 insBefore = USD.balanceOf(address(INS));
        address treasury = CONFIG.treasury();
        uint256 treasuryBefore = USD.balanceOf(treasury);
        vm.recordLogs();
        uint256 id = _open(ALICE, false);
        (uint256 deposited, uint256 insured, uint256 treasuryFee) = _feeTotals(vm.getRecordedLogs());
        assertGt(deposited, 0);
        assertEq(USD.balanceOf(address(INS)) - insBefore, insured);
        assertEq(USD.balanceOf(treasury) - treasuryBefore, treasuryFee);
        assertEq(VAULT.eligibleShares(ALICE, address(USD)), VAULT.freeBalance(ALICE, address(USD)) + MARGIN);
        assertLt(FEES.pendingRewards(ALICE, address(USD)) + FEES.pendingRewards(BOB, address(USD)), 604802);
        uint256 aliceShares = VAULT.eligibleShares(ALICE, address(USD));
        uint256 bobShares = VAULT.eligibleShares(BOB, address(USD));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(
            FEES.pendingRewards(ALICE, address(USD)), deposited * aliceShares / (aliceShares + bobShares), 3
        );
        assertApproxEqAbs(FEES.pendingRewards(BOB, address(USD)), deposited * bobShares / (aliceShares + bobShares), 3);
        _price(10e8);
        vm.recordLogs();
        _close(ALICE, id, 10_000);
        (uint256 closeRewards,,) = _feeTotals(vm.getRecordedLogs());
        assertGt(closeRewards, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 pending = FEES.pendingRewards(BOB, address(USD));
        uint256 freeBefore = VAULT.freeBalance(BOB, address(USD));
        vm.prank(BOB);
        VAULT.settle(address(USD));
        assertEq(VAULT.freeBalance(BOB, address(USD)) - freeBefore, pending);
        _withdraw(ALICE);
        _withdraw(BOB);
        _noDebt();
    }

    function testLateDepositorCannotClaimPastFees() public {
        _fees();
        uint256 id = _open(ALICE, false);
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        uint256 aliceAccrued = FEES.pendingRewards(ALICE, address(USD));
        assertGt(aliceAccrued, 0);
        _fund(BOB, MARGIN * 10);
        assertEq(FEES.pendingRewards(BOB, address(USD)), 0);
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        assertGt(FEES.pendingRewards(BOB, address(USD)), 0);
        assertGt(FEES.pendingRewards(ALICE, address(USD)), FEES.pendingRewards(BOB, address(USD)));
        assertGe(FEES.pendingRewards(ALICE, address(USD)), aliceAccrued);
        _price(10e8);
        _close(ALICE, id, 10_000);
        _noDebt();
    }

    function _fees() private {
        vm.startPrank(OWNER);
        CONFIG.queueFees(10, 10, 5000, 3000, 2000);
        vm.warp(vm.getBlockTimestamp() + CONFIG.actionDelay());
        CONFIG.setFees(10, 10, 5000, 3000, 2000);
        vm.stopPrank();
        _price(10e8);
    }

    function _feeTotals(Vm.Log[] memory logs)
        private
        view
        returns (uint256 depositor, uint256 insurance, uint256 treasury)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(FEES)
                    || logs[i].topics[0] != keccak256("FeeCollected(address,uint256,uint256,uint256,uint256)")
            ) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(USD));
            (uint256 amount, uint256 d, uint256 ins, uint256 t) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(d, amount * 5000 / 10_000);
            assertEq(ins, amount * 3000 / 10_000);
            assertEq(d + ins + t, amount);
            depositor += d;
            insurance += ins;
            treasury += t;
            ++count;
        }
        assertGt(count, 0);
    }

    function _fund(address user, uint256 shares) private {
        vm.prank(OWNER);
        assertTrue(USD.transfer(user, shares));
        vm.startPrank(user);
        USD.approve(address(VAULT), shares);
        VAULT.deposit(address(USD), shares);
        USD.approve(address(VAULT), 0);
        vm.stopPrank();
    }

    function _price(int256 answer) private {
        vm.startPrank(OWNER);
        AF.setAnswer(answer);
        UF.setAnswer(1e8);
        vm.stopPrank();
    }

    function _open(address user, bool short) private returns (uint256 id) {
        uint256 rate = USD.exchangeRateCurrent();
        AVAX.accrueInterest();
        address pos = short ? address(USD) : address(AVAX);
        address debt = short ? address(AVAX) : address(USD);
        (, uint256 minOut) = EX.quoter().quoteOpen(address(USD), pos, debt, MARGIN * rate / 1e18, 500);
        vm.prank(user);
        id = EX.openPosition(
            Executor.OpenParams(
                address(USD), pos, debt, MARGIN, 500, MARGIN / 100, minOut, short ? T.Side.SHORT : T.Side.LONG, ""
            )
        );
    }

    function _closeParams(uint256 id, uint16 bps) private pure returns (Executor.CloseParams memory) {
        return Executor.CloseParams(id, bps, MARGIN / 100, 0, 0, "", "");
    }

    function _close(address user, uint256 id, uint16 bps) private {
        Executor.CloseParams memory q = _closeParams(id, bps);
        vm.prank(user);
        EX.closePosition(q);
    }

    function _liq(uint256 id) private pure returns (Liquidator.LiquidationParams memory) {
        return Liquidator.LiquidationParams(id, KEEPER, 0, 0, "", "");
    }

    function _account(uint256 id) private view returns (address a) {
        (,, a,,,,,,,,,) = EX.positions(id);
    }

    function _status(uint256 id) private view returns (T.Status s) {
        (,,,,,,,,,,, s) = EX.positions(id);
    }

    function _noDebt() private view {
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertEq(USD.totalBorrowShares(), 0);
        assertEq(AVAX.totalBorrowShares(), 0);
    }

    function _withdraw(address user) private {
        vm.startPrank(user);
        VAULT.settle(address(USD));
        uint256 free = VAULT.freeBalance(user, address(USD));
        uint256 before = USD.balanceOf(user);
        VAULT.withdraw(address(USD), free);
        vm.stopPrank();
        assertEq(USD.balanceOf(user), before + free);
        assertEq(VAULT.freeBalance(user, address(USD)), 0);
        assertEq(VAULT.lockedBalance(user, address(USD)), 0);
    }
}
