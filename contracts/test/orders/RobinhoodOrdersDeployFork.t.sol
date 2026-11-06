// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";
import {MarginOrderRegistry} from "../../contracts/margin/orders/MarginOrderRegistry.sol";
import {IMarginOrderRegistry, IMarginCloseAdapter} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";
import {DeployRobinhoodOrders} from "../../script/orders/DeployRobinhoodOrders.s.sol";

interface IDeployForkTimelock {
    function isOperationReady(bytes32 id) external view returns (bool);
}

interface IDeployForkVault {
    function freeBalance(address, address) external view returns (uint256);
}

interface IDeployForkLiquidator {
    struct LiquidationParams {
        uint256 positionId;
        address recipient;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes collateralToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function liquidate(LiquidationParams calldata params) external;
}

/// @notice The full Robinhood TP/SL stack against the LIVE margin contracts at a fresh pin: the script's own deploy of
/// MarginOrderRegistry behind its OZ 5 proxy plus the close adapter, the Ledger's timelock pair through the real timelock
/// and ProxyAdmin, the script's verify, then real orders on a live position (position 4 at the time of writing): create,
/// canExecute, permissionless execute, mutual cancellation, a stale feed, liquidation independence. Nothing is sent.
contract RobinhoodOrdersDeployForkTest is DeployRobinhoodOrders, StdAssertions {
    address constant VAULT = 0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e;
    address constant LIQUIDATOR = 0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    string constant JOURNAL = "deployments/orders-fork-test-journal.json";
    IMarginOrderRegistry.OrderKind constant TP = IMarginOrderRegistry.OrderKind.TAKE_PROFIT;
    IMarginOrderRegistry.OrderKind constant SL = IMarginOrderRegistry.OrderKind.STOP_LOSS;
    Deployment d;
    MarginOrderRegistry reg;
    int256 answer;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        vm.roll(vm.envUint("ORDERS_NATIVE_BLOCK"));
        _preconditions();
        d = _deploy(address(this), vm.getCode(REGISTRY_ARTIFACT));
        _postconditions(d, address(this));
        reg = MarginOrderRegistry(d.registry);
        (bool okc, bytes memory r) = FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(okc);
        (, answer,,,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
        _stamp();
    }

    function _stamp() internal {
        vm.mockCall(
            FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(9), answer, block.timestamp, block.timestamp, uint80(9))
        );
    }

    function _schedule() internal {
        vm.prank(LEDGER);
        (bool ok,) = TIMELOCK.call(scheduleCalldata(d));
        assertTrue(ok, "Ledger schedules");
    }

    function _execute() internal {
        vm.warp(block.timestamp + DELAY);
        _stamp();
        vm.prank(LEDGER);
        (bool ok,) = TIMELOCK.call(executeCalldata(d));
        assertTrue(ok, "Ledger executes");
    }

    function _pos(uint256 id) internal view returns (IsolatedMarginTypes.Position memory) {
        return IRobinhoodOrderExecutor(EXECUTOR).positions(id);
    }

    function _livePosition() internal view returns (uint256 id) {
        for (uint256 i = 1; i < IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId(); i++) {
            if (_pos(i).status == IsolatedMarginTypes.Status.ACTIVE) id = i;
        }
    }

    /// @dev A take-profit that fires at today's price (equality fires) and a stop-loss far away, for whichever side.
    function _orders(uint256 id) internal returns (uint256 tp, uint256 sl, uint256 price) {
        IMarginCloseAdapter a = reg.adapter();
        bool ok;
        (price, ok) = a.oraclePriceE18(id);
        assertTrue(ok, "fresh price");
        bool long = a.isLong(id);
        address owner = a.positionOwner(id);
        uint64 exp = uint64(block.timestamp + 7 days);
        vm.startPrank(owner);
        tp = reg.createOrder(id, TP, long, price, 10_000, 100, exp);
        sl = reg.createOrder(id, SL, !long, long ? price / 2 : price * 2, 10_000, 100, exp);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ deployment and the timelock pair
    function testTimelockPairUpgradesTheExecutorAndVerifyPasses() public {
        uint256 next = IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId();
        bytes32[] memory before = new bytes32[](next);
        for (uint256 id = 1; id < next; id++) before[id] = keccak256(abi.encode(_pos(id)));
        if (vm.exists(JOURNAL)) vm.removeFile(JOURNAL);
        _writeJournal(JOURNAL, d, REGISTRY_ARTIFACT);
        this.check(JOURNAL);
        _schedule();
        this.check(JOURNAL);
        assertFalse(IDeployForkTimelock(TIMELOCK).isOperationReady(operationId(d)));
        vm.prank(LEDGER);
        (bool early,) = TIMELOCK.call(executeCalldata(d));
        assertFalse(early, "execute before the delay is refused");
        _execute();
        this.verify(JOURNAL);
        for (uint256 id = 1; id < next; id++) assertEq(keccak256(abi.encode(_pos(id))), before[id], "position unchanged");
        vm.prank(LEDGER);
        (bool again,) = TIMELOCK.call(executeCalldata(d));
        assertFalse(again, "the operation runs once");
        vm.removeFile(JOURNAL);
    }

    function testOnlyTheLedgerCanSchedule() public {
        vm.prank(address(0xbad));
        (bool ok,) = TIMELOCK.call(scheduleCalldata(d));
        assertFalse(ok);
    }

    function testBeforeTheUpgradeAnOrderCannotCloseAndStaysOpen() public {
        uint256 id = _livePosition();
        if (id == 0) return;
        (uint256 tp,,) = _orders(id);
        (bool ex,,) = reg.canExecute(tp);
        assertTrue(ex, "trigger crossed");
        vm.expectRevert(); // the live executor has no closePositionFor yet
        reg.executeOrder(tp, "");
        assertEq(uint8(reg.getOrder(tp).status), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
    }

    // ------------------------------------------------------------------ orders on the live position
    function testTakeProfitClosesTheLivePositionAndCancelsTheStopLoss() public {
        _schedule();
        _execute();
        uint256 id = _livePosition();
        if (id == 0) {
            emit log("no active position at this pin: order demo skipped");
            return;
        }
        IsolatedMarginTypes.Position memory p = _pos(id);
        vm.prank(address(0xbad));
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.createOrder(id, TP, true, 1, 10_000, 100, uint64(block.timestamp + 1 days));
        (uint256 tp, uint256 sl, uint256 price) = _orders(id);
        (bool ex, uint256 seen, uint8 reason) = reg.canExecute(tp);
        assertTrue(ex);
        assertEq(seen, price);
        assertEq(reason, 0);
        (, , reason) = reg.canExecute(sl);
        assertEq(reason, 6, "stop-loss not reached");
        uint256 freeBefore = IDeployForkVault(VAULT).freeBalance(p.owner, p.marginPToken);
        vm.prank(address(0xbeef)); // any keeper
        assertTrue(reg.executeOrder(tp, ""));
        emit log_named_uint("position closed by take-profit", id);
        assertTrue(_pos(id).status != IsolatedMarginTypes.Status.ACTIVE, "closed");
        uint256 gained = IDeployForkVault(VAULT).freeBalance(p.owner, p.marginPToken) - freeBefore;
        emit log_named_uint("margin credited to the owner (pToken units)", gained);
        assertGt(gained, 0);
        assertEq(uint8(reg.getOrder(tp).status), uint8(IMarginOrderRegistry.OrderStatus.EXECUTED));
        assertEq(uint8(reg.getOrder(sl).status), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED), "mutual cancellation");
        assertEq(reg.openOrdersOf(id).length, 0);
    }

    function testStaleFeedMakesTheOrderWaitAndThenItExecutes() public {
        _schedule();
        _execute();
        uint256 id = _livePosition();
        if (id == 0) return;
        (uint256 tp,,) = _orders(id);
        vm.warp(block.timestamp + 13 hours); // beyond the 12 h guard, no new answer
        vm.clearMockedCalls();
        vm.mockCall(
            FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(9), answer, block.timestamp - 13 hours, block.timestamp - 13 hours, uint80(9))
        );
        (bool ex,, uint8 reason) = reg.canExecute(tp);
        assertFalse(ex);
        assertEq(reason, 5);
        vm.expectRevert(IMarginOrderRegistry.OracleUnavailable.selector);
        reg.executeOrder(tp, "");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        _stamp();
        assertTrue(reg.executeOrder(tp, ""));
    }

    function testOpenOrdersDoNotChangeALiquidation() public {
        _schedule();
        _execute();
        uint256 id = _livePosition();
        if (id == 0) return;
        IDeployForkLiquidator.LiquidationParams memory lp = IDeployForkLiquidator.LiquidationParams(id, address(this), 0, 0, "", "");
        uint256 snap = vm.snapshotState();
        (bool okWithout, bytes memory without) = LIQUIDATOR.call(abi.encodeCall(IDeployForkLiquidator.liquidate, (lp)));
        vm.revertToState(snap);
        _orders(id);
        (bool okWith, bytes memory with_) = LIQUIDATOR.call(abi.encodeCall(IDeployForkLiquidator.liquidate, (lp)));
        assertEq(okWith, okWithout, "same outcome with open orders");
        assertEq(keccak256(with_), keccak256(without), "same return or revert data");
    }

    function testPauseStopsOnlyExecutionAndOnlyTheTimelockPauses() public {
        _schedule();
        _execute();
        uint256 id = _livePosition();
        if (id == 0) return;
        (uint256 tp,,) = _orders(id);
        vm.expectRevert(MarginOrderRegistry.NotAdmin.selector);
        reg.setPaused(true);
        vm.prank(TIMELOCK);
        reg.setPaused(true);
        vm.expectRevert(MarginOrderRegistry.ExecutionPaused.selector);
        reg.executeOrder(tp, "");
        vm.prank(TIMELOCK);
        reg.setPaused(false);
        assertTrue(reg.executeOrder(tp, ""));
    }
}
