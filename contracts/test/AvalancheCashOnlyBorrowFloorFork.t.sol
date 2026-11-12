// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";
import {PeridottrollerAvalancheLegacy} from "./legacy/PeridottrollerAvalancheLegacy.sol";

/**
 * @notice Borrow cash floor (`PeridottrollerAvalanche.borrowCashFloor`) on the CASH-ONLY fixture: controller + two plain markets +
 *         guarded oracle, no margin stack, both margin hooks unset. Margin paths are verified in a separate suite
 *         (`AvalancheBorrowFloorMarginFork.t.sol`) so this fixture stays margin-free.
 *
 * ALL FLOOR VALUES BELOW ARE SYNTHETIC TEST VALUES chosen so that the cases fit the fixture's cash; they are NOT recommendations and
 * no production value is proposed. Borrowing is paused at deployment in the fixture; tests that borrow unpause it explicitly, as in
 * every other suite, and no deployment configuration in this repository unpauses it.
 */
contract AvalancheCashOnlyBorrowFloorForkTest is AvalancheCashOnlyBase {
    uint256 internal constant SYNTHETIC_FLOOR_USDC = 100_000e6; // fixture cash is 400,000 USDC
    uint256 internal constant SYNTHETIC_FLOOR_WAVAX = 3_000e18; // fixture cash is 12,000 WAVAX
    address internal constant WHALE = address(0xDEAD0001);
    bytes32 internal constant FLOOR_BASE_SLOT = keccak256(abi.encode(uint256(keccak256("peridot.avalanche.PeridottrollerAvalanche.borrowCashFloor")) - 1)) & ~bytes32(uint256(0xff));

    PeridottrollerAvalanche internal ctrl; // controller seen through the new wrapper ABI

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return; // skipped (no RPC)
        ctrl = PeridottrollerAvalanche(address(controller));
    }

    // ---------------------------------------------------------------- helpers
    /// @dev Big collateral for the borrower of ONE market, so neither the collateral factor nor the borrow cap binds before the floor
    ///      does. Only that borrower's collateral is added: funding both would inflate the cash of the other market.
    function _fundBorrowers(bool wavax) internal {
        _unpauseBorrows();
        if (wavax) {
            _mintP(pUsdc, ALICE, 2_000_000e6); // borrows WAVAX (CF 75%: about 1.5M USD of borrowing power)
            _enter(ALICE);
        } else {
            _mintP(pWavax, WHALE, 80_000e18); // borrows USDC (about 684k USD collateral at CF 60%)
            _enter(WHALE);
        }
    }

    function _market(bool wavax) internal view returns (PErc20Delegator) {
        return wavax ? pWavax : pUsdc;
    }

    function _borrower(bool wavax) internal pure returns (address) {
        return wavax ? ALICE : WHALE;
    }

    function _synthFloor(bool wavax) internal pure returns (uint256) {
        return wavax ? SYNTHETIC_FLOOR_WAVAX : SYNTHETIC_FLOOR_USDC;
    }

    function _setFloor(bool wavax, uint256 floor) internal {
        assertEq(ctrl._setBorrowCashFloor(PToken(address(_market(wavax))), floor), 0);
    }

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68 || bytes4(ret) != bytes4(0x08c379a0)) return "";
        bytes memory tail = new bytes(ret.length - 4);
        for (uint256 i; i < tail.length; ++i) tail[i] = ret[i + 4];
        return abi.decode(tail, (string));
    }

    function _assertFloorRevert(bytes memory ret) internal pure {
        assertEq(_reason(ret), "borrow cash floor", "reverts with 'borrow cash floor'");
    }

    // ================================================================= floor accessors / storage / admin
    function testFloor_DefaultsToZero_AdminOnly_ListedOnly_EventAndGetter() public {
        assertEq(ctrl.borrowCashFloor(address(pUsdc)), 0);
        assertEq(ctrl.borrowCashFloor(address(pWavax)), 0);
        // only the admin
        vm.prank(ALICE);
        vm.expectRevert(bytes("only admin can set borrow cash floor"));
        ctrl._setBorrowCashFloor(PToken(address(pUsdc)), 1);
        // only listed markets
        assertEq(ctrl._setBorrowCashFloor(PToken(address(0xBAD)), 1), 9, "MARKET_NOT_LISTED"); // Error.MARKET_NOT_LISTED = 9
        assertEq(ctrl.borrowCashFloor(address(0xBAD)), 0);
        // event + getter
        vm.expectEmit(true, false, false, true, address(controller));
        emit PeridottrollerAvalanche.NewBorrowCashFloor(PToken(address(pUsdc)), 0, SYNTHETIC_FLOOR_USDC);
        assertEq(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), SYNTHETIC_FLOOR_USDC), 0);
        assertEq(ctrl.borrowCashFloor(address(pUsdc)), SYNTHETIC_FLOOR_USDC);
        assertEq(ctrl.borrowCashFloor(address(pWavax)), 0, "other market untouched");
    }

    /// @dev The floor lives in a namespaced hash slot: no linear slot of the proxy changes, so a future base that appends storage
    ///      cannot collide with it; and the value is exactly where the ERC-7201 style derivation says.
    function testStorage_NamespacedSlot_NoLinearSlotTouched() public {
        uint256 N = 200; // linear region of the controller storage (V1..V8 and headroom)
        bytes32[] memory before_ = new bytes32[](N);
        for (uint256 i; i < N; ++i) before_[i] = vm.load(address(controller), bytes32(i));
        _setFloor(false, SYNTHETIC_FLOOR_USDC);
        _setFloor(true, SYNTHETIC_FLOOR_WAVAX);
        for (uint256 i; i < N; ++i) assertEq(vm.load(address(controller), bytes32(i)), before_[i], "linear slot changed");
        bytes32 slotU = keccak256(abi.encode(address(pUsdc), FLOOR_BASE_SLOT));
        bytes32 slotW = keccak256(abi.encode(address(pWavax), FLOOR_BASE_SLOT));
        assertEq(uint256(vm.load(address(controller), slotU)), SYNTHETIC_FLOOR_USDC, "mapping entry at the namespaced slot (USDC)");
        assertEq(uint256(vm.load(address(controller), slotW)), SYNTHETIC_FLOOR_WAVAX, "mapping entry at the namespaced slot (WAVAX)");
        assertTrue(uint256(FLOOR_BASE_SLOT) > N, "namespaced base is far outside the linear region");
        assertEq(uint256(FLOOR_BASE_SLOT) & 0xff, 0, "ERC-7201 low byte cleared");
    }

    // ================================================================= at / one above / one below / already below, both markets
    function _boundary(bool wavax) internal {
        _fundBorrowers(wavax);
        PErc20Delegator m = _market(wavax);
        address b = _borrower(wavax);
        uint256 floor = _synthFloor(wavax);
        uint256 cash = m.getCash();
        assertGt(cash, floor, "fixture cash exceeds the synthetic floor");
        uint256 max = cash - floor;
        _setFloor(wavax, floor);

        uint256 snap = vm.snapshotState();
        // one above the maximum: rejected by the floor
        (bool ok,) = _borrow(m, b, max + 1);
        assertFalse(ok, "max + 1 rejected");
        _assertFloorRevert(lastRevert);
        // exactly at the floor: allowed, cash == floor afterwards
        (ok,) = _borrow(m, b, max);
        assertTrue(ok, "borrow leaving cash exactly at the floor is allowed");
        assertEq(m.getCash(), floor, "cash == floor");
        // already AT the floor: any further borrow (even 1 unit) is rejected
        (ok,) = _borrow(m, b, 1);
        assertFalse(ok, "at the floor: 1 unit rejected");
        _assertFloorRevert(lastRevert);
        vm.revertToState(snap);

        // one unit BELOW the maximum: allowed, cash == floor + 1
        (ok,) = _borrow(m, b, max - 1);
        assertTrue(ok, "max - 1 allowed");
        assertEq(m.getCash(), floor + 1);
        (ok,) = _borrow(m, b, 1);
        assertTrue(ok, "one more unit down to the floor is allowed");
        (ok,) = _borrow(m, b, 1);
        assertFalse(ok, "and the next one is not");
        vm.revertToState(snap);

        // ALREADY BELOW the floor (floor raised above current cash): every new borrow is rejected, including 1 unit
        _setFloor(wavax, cash + 1);
        (ok,) = _borrow(m, b, 1);
        assertFalse(ok, "already below the floor: 1 unit rejected");
        _assertFloorRevert(lastRevert);
        // and also when cash is below the floor because suppliers withdrew
        vm.revertToState(snap);
        _setFloor(wavax, floor);
        (bool rok,) = _redeemUnderlying(m, LP, cash - floor / 2); // supplier withdrawal below the floor is allowed (cash permitting)
        assertTrue(rok, "supplier withdrawal below the floor is allowed");
        assertLt(m.getCash(), floor);
        (ok,) = _borrow(m, b, 1);
        assertFalse(ok, "below the floor after a withdrawal: rejected");
        _assertFloorRevert(lastRevert);
    }

    function testBoundary_USDC() public { _boundary(false); }
    function testBoundary_WAVAX() public { _boundary(true); }

    // ================================================================= precedence: pause and error codes win over the floor
    function testPrecedence_PausedAndErrorCodesKeepTheirReasons() public {
        _fundBorrowers(false);
        uint256 cash = pUsdc.getCash();
        _setFloor(false, cash + 1); // every borrow violates the floor
        // an over-liquidity borrow keeps its original error code (not the floor revert)
        _mintP(pWavax, DAVE, 1e18); // tiny collateral
        _enter(DAVE);
        (bool ok, uint256 code) = _borrow(pUsdc, DAVE, 1_000e6);
        assertFalse(ok);
        assertEq(lastRevert.length >= 36 ? _revertCode(lastRevert) : code, 4, "INSUFFICIENT_LIQUIDITY (4) is returned/raised, not the floor");
        // a paused market keeps "borrow is paused"
        controller._setBorrowPaused(PErc20(address(pUsdc)), true);
        (ok,) = _borrow(pUsdc, WHALE, 1e6);
        assertFalse(ok);
        assertEq(keccak256(bytes(_reason(lastRevert))), keccak256("borrow is paused"), "pause keeps precedence");
        // a stale price keeps PRICE_ERROR
        controller._setBorrowPaused(PErc20(address(pUsdc)), false);
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        (ok,) = _borrow(pUsdc, WHALE, 1e6);
        assertFalse(ok);
        assertEq(_revertCode(lastRevert), PRICE_ERROR_CODE, "PRICE_ERROR keeps precedence");
    }

    function testBorrowingStaysPaused_FloorDoesNotUnpause() public {
        assertTrue(controller.borrowGuardianPaused(address(pUsdc)) && controller.borrowGuardianPaused(address(pWavax)), "paused at deployment");
        _setFloor(false, SYNTHETIC_FLOOR_USDC);
        _setFloor(true, SYNTHETIC_FLOOR_WAVAX);
        assertTrue(controller.borrowGuardianPaused(address(pUsdc)) && controller.borrowGuardianPaused(address(pWavax)), "setting floors does not unpause");
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok);
        assertEq(keccak256(bytes(_reason(lastRevert))), keccak256("borrow is paused"));
    }

    // ================================================================= everything that is not a new borrow keeps its behaviour below the floor
    /// @dev Runs `act` from the same state with the floor at its synthetic value (cash already below it) and with the floor disabled
    ///      and returns both outcome digests: they must be equal.
    function _digest(address[] memory who) internal returns (bytes32 h) {
        h = keccak256(abi.encode(pUsdc.getCash(), pWavax.getCash(), pUsdc.totalBorrows(), pWavax.totalBorrows(), pUsdc.totalSupply(), pWavax.totalSupply(), pUsdc.totalReserves(), pWavax.totalReserves()));
        for (uint256 i; i < who.length; ++i) {
            h = keccak256(abi.encode(h, pUsdc.balanceOf(who[i]), pWavax.balanceOf(who[i]), IERC20(USDC).balanceOf(who[i]), IERC20(WAVAX).balanceOf(who[i]), pUsdc.borrowBalanceStored(who[i]), pWavax.borrowBalanceStored(who[i])));
        }
    }

    function _who() internal pure returns (address[] memory w) {
        w = new address[](5);
        w[0] = LP; w[1] = DAVE; w[2] = BOB; w[3] = CAROL; w[4] = WHALE;
    }

    function testNonBorrowPaths_UnchangedBelowTheFloor() public {
        _fundBorrowers(false);
        // positions (created before the floor exists)
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6); // USDC debt, WAVAX collateral
        assertTrue(ok);
        _mintP(pUsdc, BOB, 1_000e6);
        _enter(BOB);
        (ok,) = _borrow(pWavax, BOB, 80e18); // WAVAX debt, USDC collateral
        assertTrue(ok);
        // drain pUSDC below any floor
        (ok,) = _borrow(pUsdc, WHALE, pUsdc.getCash() - 50e6);
        assertTrue(ok, "drain");
        uint256 floor = SYNTHETIC_FLOOR_USDC;
        assertLt(pUsdc.getCash(), floor, "pUSDC cash is below the synthetic floor");
        _setFloor(false, floor);
        _setFloor(true, SYNTHETIC_FLOOR_WAVAX);
        uint256 s0 = vm.snapshotState();
        uint256[] memory a = new uint256[](6);
        bytes32[] memory d = new bytes32[](6);

        for (uint256 pass; pass < 2; ++pass) {
            // pass 0: floors active; pass 1: floors disabled (same starting state)
            if (pass == 1) { _setFloor(false, 0); _setFloor(true, 0); }
            // (1) repay: partial, adds cash
            (ok,) = _repay(pUsdc, DAVE, 100e6);
            assertTrue(ok, "repay below the floor");
            // (2) supplier withdrawal up to the available cash, and not beyond
            (bool w1,) = _redeemUnderlying(pUsdc, LP, 40e6);
            (bool w2,) = _redeemUnderlying(pUsdc, LP, 1_000_000e6);
            // (3) ordinary liquidation, both directions
            _setAvaxBps(6_600);
            (bool l1,, uint256 s1) = _liquidate(pUsdc, pWavax, DAVE, 100e6); // USDC debt, AVAX down
            _setAvaxBps(12_000);
            (bool l2,, uint256 s2) = _liquidate(pWavax, pUsdc, BOB, 20e18); // WAVAX debt, AVAX up
            a[0] = w1 ? 1 : 0; a[1] = w2 ? 1 : 0; a[2] = l1 ? 1 : 0; a[3] = l2 ? 1 : 0; a[4] = s1; a[5] = s2;
            d[pass] = _digest(_who());
            assertTrue(w1, "withdrawal within cash works");
            assertFalse(w2, "withdrawal beyond cash fails as before");
            assertTrue(l1 && l2, "ordinary liquidation works below the floor");
            if (pass == 0) vm.revertToState(s0);
        }
        assertEq(d[0], d[1], "end state identical with the floor active and with the floor disabled");
        a;
    }

    // ================================================================= floor disabled == pre-floor controller (differential), and live upgrade
    struct Obs { bool ok; bytes ret; uint256 liqErr; uint256 liqShort; bytes32 st; }

    function _scenario() internal returns (bytes32 h) {
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok, uint256 code) = _borrow(pUsdc, DAVE, 100e6);
        h = keccak256(abi.encode(ok, code, lastRevert));
        (ok, code) = _borrow(pUsdc, DAVE, 480e6);
        h = keccak256(abi.encode(h, ok, code, lastRevert));
        (ok, code) = _borrow(pUsdc, DAVE, 600e6); // beyond the collateral factor
        h = keccak256(abi.encode(h, ok, code, lastRevert));
        (ok, code) = _borrow(pWavax, DAVE, 1e18); // a second borrow market with thin collateral left
        h = keccak256(abi.encode(h, ok, code, lastRevert));
        (uint256 e, uint256 liq, uint256 sf) = controller.getAccountLiquidity(DAVE);
        h = keccak256(abi.encode(h, e, liq, sf, pUsdc.getCash(), pUsdc.totalBorrows()));
        (ok, code) = _repay(pUsdc, DAVE, 50e6);
        h = keccak256(abi.encode(h, ok, code));
        _setAvaxBps(6_600);
        (bool lok, uint256 lcode, uint256 seized) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        h = keccak256(abi.encode(h, lok, lcode, seized, pUsdc.totalBorrows(), pWavax.totalSupply()));
        (ok, code) = _borrow(pUsdc, DAVE, 1e6); // underwater
        h = keccak256(abi.encode(h, ok, code, lastRevert));
        _setAvaxBps(10_000);
        controller._setBorrowPaused(PErc20(address(pUsdc)), true);
        (ok, code) = _borrow(pUsdc, DAVE, 1e6); // paused
        h = keccak256(abi.encode(h, ok, code, lastRevert));
    }

    function _switchTo(address impl) internal {
        require(unitroller._setPendingImplementation(impl) == 0, "pending");
        // `_become` is defined on the implementation (Peridottroller); call it through the generic selector
        (bool ok,) = impl.call(abi.encodeWithSignature("_become(address)", address(unitroller)));
        require(ok, "become");
    }

    function testDisabledFloor_BehavesLikeThePreFloorController() public {
        _unpauseBorrows();
        address legacyImpl = address(new PeridottrollerAvalancheLegacy(address(peridot)));
        address newImpl = unitroller.peridottrollerImplementation();
        uint256 snap = vm.snapshotState();
        _switchTo(legacyImpl);
        assertEq(unitroller.peridottrollerImplementation(), legacyImpl);
        bytes32 hLegacy = _scenario();
        vm.revertToState(snap);
        vm.clearMockedCalls();
        _setAvaxBps(10_000);
        assertEq(unitroller.peridottrollerImplementation(), newImpl);
        bytes32 hNew = _scenario();
        assertEq(hNew, hLegacy, "floor disabled: identical codes, revert data, liquidity, liquidation outcome");
    }

    function testUpgrade_LegacyToFloorController_PreservesStateThenEnforces() public {
        _unpauseBorrows();
        address newImpl = unitroller.peridottrollerImplementation();
        address legacyImpl = address(new PeridottrollerAvalancheLegacy(address(peridot)));
        _switchTo(legacyImpl); // live state is created under the pre-floor controller
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 400e6);
        assertTrue(ok);
        (uint256 e0, uint256 l0, uint256 s0) = controller.getAccountLiquidity(DAVE);
        uint256 cap0 = controller.borrowCaps(address(pUsdc));
        bytes32 raw0 = keccak256(abi.encodePacked(vm.load(address(controller), bytes32(uint256(3))), vm.load(address(controller), bytes32(uint256(5)))));
        _switchTo(newImpl);
        (uint256 e1, uint256 l1, uint256 s1) = controller.getAccountLiquidity(DAVE);
        assertTrue(e0 == e1 && l0 == l1 && s0 == s1, "account liquidity unchanged by the upgrade");
        assertEq(controller.borrowCaps(address(pUsdc)), cap0, "caps preserved");
        assertEq(address(controller.oracle()), address(oracle));
        assertEq(controller.closeFactorMantissa(), 0.5e18);
        raw0;
        // the new controller enforces a floor on the state created under the old one
        uint256 cash = pUsdc.getCash();
        _setFloor(false, cash); // any further borrow breaks it
        (ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok);
        _assertFloorRevert(lastRevert);
        (ok,) = _repay(pUsdc, DAVE, 100e6);
        assertTrue(ok, "repay still works");
        // rolling back to the pre-floor controller keeps the (now inert) floor value in its namespaced slot without effect
        _switchTo(legacyImpl);
        (ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertTrue(ok, "rollback to the pre-floor controller: no floor enforced");
        _switchTo(newImpl);
        assertEq(ctrl.borrowCashFloor(address(pUsdc)), cash, "floor value survived the round trip");
    }
}
