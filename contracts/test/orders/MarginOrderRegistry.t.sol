// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MarginOrderRegistry} from "../../contracts/margin/orders/MarginOrderRegistry.sol";
import {IMarginOrderRegistry, IMarginCloseAdapter} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";

contract MockCloseAdapter is IMarginCloseAdapter {
    struct P {
        address owner;
        bool active;
        bool long;
    }

    mapping(uint256 => P) public pos;
    uint256 public price = 100e18;
    bool public priceOk = true;
    bool public closeReverts;
    bool public partialKeepsActive = true;
    bool public reenter;
    uint256 public reenterId = 1;
    address public registry;
    uint256 public calls;
    uint256 public lastPrice;
    uint16 public lastBps;
    uint16 public lastSlip;
    address public lastOwner;

    function setRegistry(address r) external {
        registry = r;
    }

    function set(uint256 id, address owner, bool active, bool long) external {
        pos[id] = P(owner, active, long);
    }

    function setPrice(uint256 p, bool ok) external {
        price = p;
        priceOk = ok;
    }

    function setCloseReverts(bool b) external {
        closeReverts = b;
    }

    function setPartialKeepsActive(bool b) external {
        partialKeepsActive = b;
    }

    function setReenter(bool b) external {
        reenter = b;
    }

    function setReenterId(uint256 id) external {
        reenterId = id;
    }

    function positionOwner(uint256 id) external view returns (address) {
        return pos[id].owner;
    }

    function isActive(uint256 id) external view returns (bool) {
        return pos[id].active;
    }

    function isLong(uint256 id) external view returns (bool) {
        return pos[id].long;
    }

    function oraclePriceE18(uint256) external view returns (uint256, bool) {
        return (price, priceOk);
    }

    function closeFor(uint256 id, address owner, uint16 closeBps, uint256 p, uint16 slip, bytes calldata)
        external
        returns (uint256)
    {
        require(msg.sender == registry, "NOT_REGISTRY");
        require(!closeReverts, "CLOSE_FAILED");
        if (reenter) IMarginOrderRegistry(registry).executeOrder(reenterId, "");
        calls++;
        lastPrice = p;
        lastBps = closeBps;
        lastSlip = slip;
        lastOwner = owner;
        if (closeBps == 10_000 || !partialKeepsActive) pos[id].active = false;
        return 777;
    }
}

contract MarginOrderRegistryTest is Test {
    MarginOrderRegistry reg;
    MockCloseAdapter ad;
    address timelock = address(0x71);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant LONG = 1;
    uint256 constant SHORT = 2;
    IMarginOrderRegistry.OrderKind constant TP = IMarginOrderRegistry.OrderKind.TAKE_PROFIT;
    IMarginOrderRegistry.OrderKind constant SL = IMarginOrderRegistry.OrderKind.STOP_LOSS;

    function setUp() public {
        vm.warp(1_800_000_000);
        ad = new MockCloseAdapter();
        MarginOrderRegistry impl = new MarginOrderRegistry();
        reg = MarginOrderRegistry(
            address(new TransparentUpgradeableProxy(address(impl), timelock, abi.encodeCall(MarginOrderRegistry.initialize, (ad, timelock))))
        );
        ad.setRegistry(address(reg));
        ad.set(LONG, alice, true, true);
        ad.set(SHORT, alice, true, false);
    }

    function _exp() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _tp(uint256 trigger) internal returns (uint256) {
        vm.prank(alice);
        return reg.createOrder(LONG, TP, true, trigger, 10_000, 100, _exp());
    }

    function _sl(uint256 trigger, uint16 bps) internal returns (uint256) {
        vm.prank(alice);
        return reg.createOrder(LONG, SL, false, trigger, bps, 100, _exp());
    }

    function _status(uint256 id) internal view returns (IMarginOrderRegistry.OrderStatus) {
        return reg.getOrder(id).status;
    }

    // ------------------------------------------------------------------ deployment convention
    function testInitializedOnceAndImplementationLocked() public {
        assertEq(address(reg.adapter()), address(ad));
        assertEq(reg.admin(), timelock);
        assertEq(reg.nextOrderId(), 1);
        vm.expectRevert();
        reg.initialize(ad, bob);
        MarginOrderRegistry impl = new MarginOrderRegistry();
        vm.expectRevert();
        impl.initialize(ad, bob);
    }

    function testInitializeRejectsZeroConfig() public {
        MarginOrderRegistry impl = new MarginOrderRegistry();
        vm.expectRevert();
        new TransparentUpgradeableProxy(
            address(impl), timelock, abi.encodeCall(MarginOrderRegistry.initialize, (IMarginCloseAdapter(address(0)), timelock))
        );
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(impl), timelock, abi.encodeCall(MarginOrderRegistry.initialize, (ad, address(0))));
    }

    // ------------------------------------------------------------------ create
    function testCreateStoresEverythingAndListsOpen() public {
        uint256 id = _tp(120e18);
        assertEq(id, 1);
        IMarginOrderRegistry.Order memory o = reg.getOrder(id);
        assertEq(o.positionId, LONG);
        assertEq(o.owner, alice);
        assertEq(uint8(o.kind), uint8(TP));
        assertTrue(o.triggerAbove);
        assertEq(o.triggerPriceE18, 120e18);
        assertEq(o.closeBps, 10_000);
        assertEq(o.maxSlippageBps, 100);
        assertEq(o.expiry, _exp());
        assertEq(o.createdAt, block.timestamp);
        assertEq(o.updatedAt, block.timestamp);
        assertEq(uint8(o.status), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        assertEq(reg.openOrdersOf(LONG).length, 1);
        assertEq(reg.nextOrderId(), 2);
    }

    function testCreateOnlyByThePositionOwnerAndOnlyWhileActive() public {
        vm.prank(bob);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, _exp());
        ad.set(LONG, alice, false, true);
        vm.prank(alice);
        vm.expectRevert(IMarginOrderRegistry.PositionNotActive.selector);
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, _exp());
    }

    function testDirectionMustMatchTheSide() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(1)));
        reg.createOrder(LONG, TP, false, 120e18, 10_000, 100, _exp());
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(1)));
        reg.createOrder(LONG, SL, true, 80e18, 10_000, 100, _exp());
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(1)));
        reg.createOrder(SHORT, TP, true, 80e18, 10_000, 100, _exp());
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(1)));
        reg.createOrder(SHORT, SL, false, 120e18, 10_000, 100, _exp());
        reg.createOrder(SHORT, TP, false, 80e18, 10_000, 100, _exp());
        reg.createOrder(SHORT, SL, true, 120e18, 10_000, 100, _exp());
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, _exp());
        reg.createOrder(LONG, SL, false, 80e18, 10_000, 100, _exp());
        vm.stopPrank();
    }

    function testFieldBoundsAndTheirCodes() public {
        vm.startPrank(alice);
        uint64 e = _exp();
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(2)));
        reg.createOrder(LONG, TP, true, 120e18, 0, 100, e);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(2)));
        reg.createOrder(LONG, TP, true, 120e18, 10_001, 100, e);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(3)));
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 0, e);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(3)));
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 301, e);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(4)));
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(4)));
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, 0);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(4)));
        reg.createOrder(LONG, TP, true, 120e18, 10_000, 100, uint64(block.timestamp + 30 days + 1));
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(5)));
        reg.createOrder(LONG, TP, true, 0, 10_000, 100, e);
        // the exact edges are accepted
        reg.createOrder(LONG, TP, true, 1, 1, 1, uint64(block.timestamp + 1));
        reg.createOrder(LONG, TP, true, 1, 10_000, 300, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function testAtMostFourOpenOrdersPerPosition() public {
        for (uint256 i; i < 4; i++) _tp(120e18 + i);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(6)));
        reg.createOrder(LONG, TP, true, 130e18, 10_000, 100, _exp());
        vm.prank(alice);
        reg.cancelOrder(2);
        _tp(130e18); // a freed slot is reusable
        assertEq(reg.openOrdersOf(LONG).length, 4);
    }

    // ------------------------------------------------------------------ modify / cancel
    function testModifyReplacesOnlyTheMutableFields() public {
        uint256 id = _tp(120e18);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        reg.modifyOrder(id, 125e18, 5000, 200, uint64(block.timestamp + 2 days));
        IMarginOrderRegistry.Order memory o = reg.getOrder(id);
        assertEq(o.triggerPriceE18, 125e18);
        assertEq(o.closeBps, 5000);
        assertEq(o.maxSlippageBps, 200);
        assertEq(o.expiry, block.timestamp + 2 days);
        assertEq(o.updatedAt, block.timestamp);
        assertEq(o.createdAt, block.timestamp - 10);
        assertEq(uint8(o.kind), uint8(TP));
        assertTrue(o.triggerAbove);
        assertEq(o.positionId, LONG);
    }

    function testModifyRules() public {
        uint256 id = _tp(120e18);
        vm.prank(bob);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.modifyOrder(id, 125e18, 10_000, 100, _exp());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(3)));
        reg.modifyOrder(id, 125e18, 10_000, 301, _exp());
        ad.set(LONG, alice, false, true);
        vm.prank(alice);
        vm.expectRevert(IMarginOrderRegistry.PositionNotActive.selector);
        reg.modifyOrder(id, 125e18, 10_000, 100, _exp());
        ad.set(LONG, bob, true, true); // owner changed: neither the old nor the new owner may modify
        vm.prank(alice);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.modifyOrder(id, 125e18, 10_000, 100, _exp());
        vm.prank(bob);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.modifyOrder(id, 125e18, 10_000, 100, _exp());
    }

    function testExpiredOrderCannotBeModifiedAndCancelMarksItExpired() public {
        uint256 id = _tp(120e18);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(IMarginOrderRegistry.OrderNotOpen.selector);
        reg.modifyOrder(id, 125e18, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.prank(alice);
        reg.cancelOrder(id);
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.EXPIRED));
        assertEq(reg.openOrdersOf(LONG).length, 0);
    }

    function testCancelByOrderOwnerOnlyEvenAfterThePositionClosed() public {
        uint256 id = _tp(120e18);
        vm.prank(bob);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        reg.cancelOrder(id);
        ad.set(LONG, alice, false, true);
        vm.expectEmit(true, true, false, true);
        emit IMarginOrderRegistry.OrderCancelled(id, LONG, 0);
        vm.prank(alice);
        reg.cancelOrder(id);
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
        vm.prank(alice);
        vm.expectRevert(IMarginOrderRegistry.OrderNotOpen.selector);
        reg.cancelOrder(id);
    }

    // ------------------------------------------------------------------ execute: the SPEC order
    function testExecuteNotOpenReverts() public {
        vm.expectRevert(IMarginOrderRegistry.OrderNotOpen.selector);
        reg.executeOrder(99, "");
    }

    function testExpiryIsCheckedFirstEvenWhenTriggered() public {
        uint256 id = _tp(90e18); // already crossed
        ad.set(LONG, alice, false, true); // and the position inactive: expiry still wins
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectEmit(true, true, false, false);
        emit IMarginOrderRegistry.OrderExpired(id, LONG);
        assertFalse(reg.executeOrder(id, ""));
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.EXPIRED));
        assertEq(ad.calls(), 0);
    }

    function testExpiryBoundaryIsInclusive() public {
        uint256 id = _tp(90e18);
        vm.warp(block.timestamp + 1 days); // == expiry: still valid
        assertTrue(reg.executeOrder(id, ""));
    }

    function testInactivePositionCancelsWithReason2() public {
        uint256 id = _tp(90e18);
        ad.set(LONG, alice, false, true);
        vm.expectEmit(true, true, false, true);
        emit IMarginOrderRegistry.OrderCancelled(id, LONG, 2);
        assertFalse(reg.executeOrder(id, ""));
        assertEq(ad.calls(), 0);
    }

    function testOwnerChangeCancelsWithReason3() public {
        uint256 id = _tp(90e18);
        ad.set(LONG, bob, true, true);
        vm.expectEmit(true, true, false, true);
        emit IMarginOrderRegistry.OrderCancelled(id, LONG, 3);
        assertFalse(reg.executeOrder(id, ""));
        assertEq(ad.calls(), 0);
    }

    function testOracleUnavailableRevertsAndTheOrderWaits() public {
        uint256 id = _tp(90e18);
        ad.setPrice(100e18, false);
        vm.expectRevert(IMarginOrderRegistry.OracleUnavailable.selector);
        reg.executeOrder(id, "");
        ad.setPrice(0, true);
        vm.expectRevert(IMarginOrderRegistry.OracleUnavailable.selector);
        reg.executeOrder(id, "");
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
    }

    function testTriggerNotReachedRevertsBothDirectionsAndEqualityFires() public {
        uint256 tp = _tp(120e18);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.TriggerNotReached.selector, 100e18, 120e18));
        reg.executeOrder(tp, "");
        uint256 sl = _sl(80e18, 10_000);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.TriggerNotReached.selector, 100e18, 80e18));
        reg.executeOrder(sl, "");
        ad.setPrice(80e18, true);
        assertTrue(reg.executeOrder(sl, ""));
    }

    function testShortTriggersAreMirrored() public {
        vm.startPrank(alice);
        uint256 tp = reg.createOrder(SHORT, TP, false, 90e18, 5000, 100, _exp());
        uint256 sl = reg.createOrder(SHORT, SL, true, 110e18, 5000, 100, _exp());
        vm.stopPrank();
        vm.expectRevert();
        reg.executeOrder(tp, "");
        vm.expectRevert();
        reg.executeOrder(sl, "");
        ad.setPrice(110e18, true);
        assertTrue(reg.executeOrder(sl, ""));
        ad.setPrice(90e18, true);
        assertTrue(reg.executeOrder(tp, ""));
    }

    function testExecutionPassesTheOrderAndTheOracleAndEmits() public {
        uint256 id = _sl(105e18, 10_000);
        vm.expectEmit(true, true, true, true);
        emit IMarginOrderRegistry.OrderExecuted(id, LONG, bob, 100e18, 10_000, 777);
        vm.prank(bob); // permissionless
        assertTrue(reg.executeOrder(id, hex"aa"));
        assertEq(ad.lastOwner(), alice, "proceeds owner is the order owner, never the caller");
        assertEq(ad.lastPrice(), 100e18);
        assertEq(ad.lastBps(), 10_000);
        assertEq(ad.lastSlip(), 100);
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.EXECUTED));
        vm.expectRevert(IMarginOrderRegistry.OrderNotOpen.selector);
        reg.executeOrder(id, "");
    }

    function testCloseRevertLeavesTheOrderOpen() public {
        uint256 id = _sl(105e18, 10_000);
        ad.setCloseReverts(true);
        vm.expectRevert(bytes("CLOSE_FAILED"));
        reg.executeOrder(id, "");
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        assertEq(reg.openOrdersOf(LONG).length, 1);
    }

    // ------------------------------------------------------------------ mutual cancellation
    function testFullCloseCancelsEverySiblingWithReason1() public {
        uint256 tp = _tp(120e18);
        uint256 sl = _sl(105e18, 10_000);
        uint256 sl2 = _sl(90e18, 5000);
        vm.expectEmit(true, true, false, true);
        emit IMarginOrderRegistry.OrderCancelled(sl2, LONG, 1);
        vm.expectEmit(true, true, false, true);
        emit IMarginOrderRegistry.OrderCancelled(tp, LONG, 1);
        assertTrue(reg.executeOrder(sl, ""));
        assertEq(uint8(_status(tp)), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
        assertEq(uint8(_status(sl2)), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
        assertEq(reg.openOrdersOf(LONG).length, 0);
    }

    function testPartialThatKeepsThePositionLeavesSiblingsOpen() public {
        uint256 tp = _tp(120e18);
        uint256 sl = _sl(105e18, 5000);
        assertTrue(reg.executeOrder(sl, ""));
        assertEq(uint8(_status(tp)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        assertEq(reg.openOrdersOf(LONG).length, 1);
    }

    function testPartialThatEndsThePositionCancelsSiblings() public {
        uint256 tp = _tp(120e18);
        uint256 sl = _sl(105e18, 5000);
        ad.setPartialKeepsActive(false);
        assertTrue(reg.executeOrder(sl, ""));
        assertEq(uint8(_status(tp)), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
    }

    function testOrdersOnOtherPositionsAreUntouched() public {
        vm.prank(alice);
        uint256 other = reg.createOrder(SHORT, SL, true, 120e18, 10_000, 100, _exp());
        uint256 sl = _sl(105e18, 10_000);
        reg.executeOrder(sl, "");
        assertEq(uint8(_status(other)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
    }

    function testOwnerCloseOrLiquidationElsewhereCancelsOnNextAttempt() public {
        uint256 tp = _tp(120e18);
        uint256 sl = _sl(90e18, 10_000);
        ad.set(LONG, alice, false, true); // closed outside the registry
        ad.setPrice(150e18, true);
        assertFalse(reg.executeOrder(tp, ""));
        assertFalse(reg.executeOrder(sl, ""));
        assertEq(reg.openOrdersOf(LONG).length, 0);
        assertEq(ad.calls(), 0);
    }

    // ------------------------------------------------------------------ pause, reentrancy
    function testPauseIsAdminOnlyAndStopsOnlyExecution() public {
        vm.prank(bob);
        vm.expectRevert(MarginOrderRegistry.NotAdmin.selector);
        reg.setPaused(true);
        vm.prank(timelock);
        reg.setPaused(true);
        uint256 id = _sl(105e18, 10_000); // owners still create
        vm.expectRevert(MarginOrderRegistry.ExecutionPaused.selector);
        reg.executeOrder(id, "");
        (bool ex,, uint8 reason) = reg.canExecute(id);
        assertFalse(ex);
        assertEq(reason, 7);
        vm.prank(alice);
        reg.modifyOrder(id, 106e18, 10_000, 100, _exp());
        vm.prank(alice);
        reg.cancelOrder(id);
        vm.prank(timelock);
        reg.setPaused(false);
        uint256 id2 = _sl(105e18, 10_000);
        assertTrue(reg.executeOrder(id2, ""));
    }

    function testAdapterCannotReenterTheSameOrder() public {
        uint256 id = _sl(105e18, 10_000);
        ad.setReenter(true);
        vm.expectRevert();
        reg.executeOrder(id, "");
        assertEq(uint8(_status(id)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
    }

    /// @dev Re-entering on a sibling order is the case only the guard stops (the first order is already EXECUTED).
    function testAdapterCannotReenterASiblingOrder() public {
        uint256 first = _sl(105e18, 5000);
        uint256 sibling = _sl(104e18, 5000);
        ad.setReenter(true);
        ad.setReenterId(sibling);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        reg.executeOrder(first, "");
        assertEq(uint8(_status(first)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        assertEq(uint8(_status(sibling)), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
    }

    // ------------------------------------------------------------------ canExecute
    function testCanExecuteReasonsMatchExecute() public {
        (bool ex, uint256 p, uint8 r) = reg.canExecute(42);
        assertEq(r, 1);
        uint256 tp = _tp(120e18);
        (ex, p, r) = reg.canExecute(tp);
        assertFalse(ex);
        assertEq(p, 100e18);
        assertEq(r, 6);
        ad.setPrice(120e18, true);
        (ex, p, r) = reg.canExecute(tp);
        assertTrue(ex);
        assertEq(r, 0);
        ad.setPrice(120e18, false);
        (, , r) = reg.canExecute(tp);
        assertEq(r, 5);
        ad.set(LONG, bob, true, true);
        (, , r) = reg.canExecute(tp);
        assertEq(r, 4);
        ad.set(LONG, alice, false, true);
        (, , r) = reg.canExecute(tp);
        assertEq(r, 3);
        vm.warp(block.timestamp + 1 days + 1);
        (, , r) = reg.canExecute(tp);
        assertEq(r, 2);
    }

    function testCanExecuteNeverRevertsOnABrokenAdapter() public {
        uint256 tp = _tp(120e18);
        vm.mockCallRevert(address(ad), abi.encodeWithSelector(IMarginCloseAdapter.oraclePriceE18.selector), "X");
        (bool ex,, uint8 r) = reg.canExecute(tp);
        assertFalse(ex);
        assertEq(r, 5);
        vm.mockCallRevert(address(ad), abi.encodeWithSelector(IMarginCloseAdapter.isActive.selector), "X");
        (, , r) = reg.canExecute(tp);
        assertEq(r, 3);
    }

    // ------------------------------------------------------------------ fuzz: open-set bookkeeping
    function testFuzzOpenListAlwaysEqualsTheOpenOrders(uint256 seed) public {
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; i++) ids[i] = _sl(80e18 - i, 5000);
        for (uint256 step; step < 6; step++) {
            uint256 pick = uint256(keccak256(abi.encode(seed, step))) % 4;
            uint256 id = ids[pick];
            if (reg.getOrder(id).status != IMarginOrderRegistry.OrderStatus.OPEN) continue;
            uint256 action = uint256(keccak256(abi.encode(seed, step, "a"))) % 3;
            if (action == 0) {
                vm.prank(alice);
                reg.cancelOrder(id);
            } else if (action == 1) {
                ad.setPrice(50e18, true);
                reg.executeOrder(id, "");
                ad.setPrice(100e18, true);
            } else {
                vm.prank(alice);
                reg.modifyOrder(id, 70e18, 5000, 100, _exp());
            }
            uint256 open;
            for (uint256 j; j < 4; j++) {
                if (reg.getOrder(ids[j]).status == IMarginOrderRegistry.OrderStatus.OPEN) open++;
            }
            uint256[] memory listed = reg.openOrdersOf(LONG);
            assertEq(listed.length, open, "open list length");
            for (uint256 k; k < listed.length; k++) {
                assertEq(uint8(reg.getOrder(listed[k]).status), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
            }
        }
    }
}
