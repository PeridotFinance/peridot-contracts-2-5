// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";
import {IMarginOrderRegistry} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";
import {RangeTakeProfit} from "../../contracts/margin/orders/range/RangeTakeProfit.sol";
import {TickMath} from "../../contracts/margin/orders/range/vendor/TickMath.sol";
import {DeployRobinhoodOrders} from "../../script/orders/DeployRobinhoodOrders.s.sol";
import {DeployRangeTakeProfit, IRtpExecutorView} from "../../script/orders/DeployRangeTakeProfit.s.sol";
import {RtpTrader, IRtpPool} from "./RangeTakeProfitFork.t.sol";

interface IDeployRtpTimelock {
    function isOperationReady(bytes32 id) external view returns (bool);
}

/// @notice The production path end to end on a fork of the LIVE stack: the 15-17 Nov ceremony replayed with its own
/// script and Ledger pair, then DeployRangeTakeProfit (7 creations) and its single Ledger batch through the real
/// timelock, `check` before both signatures, `verify` after, and a range order on live position 4 finalised through the
/// new wiring. Nothing is sent.
contract RangeTakeProfitDeployForkTest is DeployRangeTakeProfit, StdAssertions {
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant PROTOCOL_TO = address(0xBEEF01);
    string constant ORDERS_J = "deployments/range-fork-orders-journal.json";
    string constant RANGE_J = "deployments/range-fork-range-journal.json";
    Ceremony c;
    Range r;
    int256 answer;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        vm.roll(vm.envUint("ORDERS_NATIVE_BLOCK"));
        (bool okc, bytes memory ret) = FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(okc);
        (, answer,,,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        _stamp();
        // The ceremony, exactly as prepared for signing (its own script and Ledger pair).
        DeployRobinhoodOrders orders = new DeployRobinhoodOrders();
        for (uint256 i; i < 2; i++) if (vm.exists(i == 0 ? ORDERS_J : RANGE_J)) vm.removeFile(i == 0 ? ORDERS_J : RANGE_J);
        DeployRobinhoodOrders.Deployment memory d = orders.deployForFork(ORDERS_J);
        _ledger(orders.scheduleCalldata(d));
        vm.warp(block.timestamp + DELAY);
        _stamp();
        _ledger(orders.executeCalldata(d));
        c = readCeremony(ORDERS_J);
    }

    function _stamp() internal {
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(9), answer, block.timestamp, block.timestamp, uint80(9)));
    }

    function _ledger(bytes memory data) internal {
        vm.prank(LEDGER);
        (bool ok,) = TIMELOCK.call(data);
        assertTrue(ok, "Ledger call");
    }

    function _deployRange() internal {
        _preconditions(c);
        r = _deploy(address(this), c, PROTOCOL_TO);
        _postconditions(c, r, address(this));
        _writeJournal(RANGE_J, c, r);
    }

    function testRangeBatchThroughTheTimelockThenVerify() public {
        _deployRange();
        this.check(RANGE_J);
        _ledger(scheduleCalldata(c, r));
        this.check(RANGE_J);
        assertFalse(IDeployRtpTimelock(TIMELOCK).isOperationReady(operationId(c, r)));
        vm.prank(LEDGER);
        (bool early,) = TIMELOCK.call(executeCalldata(c, r));
        assertFalse(early, "execute before the delay is refused");
        vm.warp(block.timestamp + DELAY);
        _stamp();
        _ledger(executeCalldata(c, r));
        this.verify(RANGE_J);
        vm.prank(LEDGER);
        (bool again,) = TIMELOCK.call(executeCalldata(c, r));
        assertFalse(again, "the batch runs once");
    }

    function testPreconditionsRefuseIfTheCeremonyHasNotRun() public {
        Ceremony memory wrong = c;
        wrong.adapterV1 = address(0xdead);
        vm.expectRevert(bytes("ORDER_EXECUTOR_NOT_V1"));
        this.preconditionsExternal(wrong);
    }

    function preconditionsExternal(Ceremony memory x) external view {
        _preconditions(x);
    }

    function testBeforeTheBatchTheCustodianRefusesBands() public {
        _deployRange();
        uint256 id = _live();
        IsolatedMarginTypes.Position memory p = IRobinhoodOrderExecutor(EXECUTOR).positions(id);
        vm.prank(p.owner);
        vm.expectRevert(); // the live risk engine has no rangeCustodian(): fail closed before anything moves
        RangeTakeProfit(r.custodian).createRangeOrder(id, 1, 0);
    }

    function _live() internal view returns (uint256 id) {
        uint256 n = IRtpExecutorView(EXECUTOR).nextPositionId();
        for (uint256 i = 1; i < n; i++) {
            IsolatedMarginTypes.Position memory q = IRobinhoodOrderExecutor(EXECUTOR).positions(i);
            if (q.status == IsolatedMarginTypes.Status.ACTIVE && q.side == IsolatedMarginTypes.Side.LONG) id = i;
        }
        require(id != 0, "no live long");
    }

    function testAfterTheBatchARangeOrderOnTheLivePositionIsFinalisedAndExclusive() public {
        _deployRange();
        _ledger(scheduleCalldata(c, r));
        vm.warp(block.timestamp + DELAY);
        _stamp();
        _ledger(executeCalldata(c, r));
        uint256 id = _live();
        IsolatedMarginTypes.Position memory p = IRobinhoodOrderExecutor(EXECUTOR).positions(id);
        RangeTakeProfit cust = RangeTakeProfit(r.custodian);
        RtpTrader trader = new RtpTrader(IRtpPool(POOL), IERC20(USDG), IERC20(NVDA));
        // Fund the pool mover from the Uniswap v4 PoolManager's balances (a script-based test has no deal; draining the
        // Ramses pool itself would leave it unable to pay out the swap).
        vm.startPrank(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        IERC20(USDG).transfer(address(trader), IERC20(USDG).balanceOf(0x8366a39CC670B4001A1121B8F6A443A643e40951) / 2);
        IERC20(NVDA).transfer(address(trader), IERC20(NVDA).balanceOf(0x8366a39CC670B4001A1121B8F6A443A643e40951) / 2);
        vm.stopPrank();
        (bool okp, bytes memory pr) = ORACLE.staticcall(abi.encodeWithSignature("getPrice(address)", NVDA));
        require(okp);
        uint256 price = abi.decode(pr, (uint256));
        trader.moveTo(uint160(Math.sqrt(Math.mulDiv(1e30, uint256(1) << 192, price))));
        vm.prank(p.owner);
        (int24 lo,,) = cust.createRangeOrder(id, 3, 0); // preset 3: 5% above the market
        vm.prank(p.owner);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(7)));
        IMarginOrderRegistry(c.registry).createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, price * 2, 10_000, 100,
            uint64(block.timestamp + 1 days));
        uint160 s = TickMath.getSqrtPriceAtTick(lo - 20);
        trader.moveTo(s);
        vm.mockCall(ORACLE, abi.encodeWithSignature("getPrice(address)", NVDA),
            abi.encode(Math.mulDiv(1e30, uint256(1) << 192, uint256(s) * uint256(s))));
        cust.finalize(id);
        assertEq(uint8(cust.getOrder(id).status), uint8(RangeTakeProfit.Status.SETTLED));
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(IERC20(USDG).balanceOf(PROTOCOL_TO), 0, "protocol share of the fees");
        vm.removeFile(ORDERS_J);
    }
}
