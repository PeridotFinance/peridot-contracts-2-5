// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheSection5Base.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice Margin paths with the controller's borrow cash floor (kept OUT of the cash-only fixture so that fixture has no margin
 *         dependency). A margin open borrows through the same `borrowAllowed` and is therefore subject to the floor; margin close,
 *         flash liquidation and funded in-kind liquidation never borrow from the market and must behave exactly as without a floor.
 *         ALL FLOOR VALUES ARE SYNTHETIC test values derived from the fixture's cash; no production value is proposed.
 */
contract AvalancheBorrowFloorMarginForkTest is AvalancheSection5Base {
    address internal constant FUNDER = CAROL;
    PeridottrollerAvalanche internal ctrl;

    function _ctrl() internal returns (PeridottrollerAvalanche) {
        if (address(ctrl) == address(0)) ctrl = PeridottrollerAvalanche(address(controller));
        return ctrl;
    }

    function _setFloor(PErc20Delegator m, uint256 floor) internal {
        assertEq(_ctrl()._setBorrowCashFloor(PToken(address(m)), floor), 0);
    }

    function _debtOf(uint256 id) internal view returns (uint256) {
        IsolatedMarginTypes.Position memory p = _position(id);
        return PErc20(p.debtPToken).borrowBalanceStored(p.account);
    }

    function _reason(bytes memory ret) internal pure returns (bytes32) {
        if (ret.length < 68 || bytes4(ret) != bytes4(0x08c379a0)) return bytes32(0);
        bytes memory tail = new bytes(ret.length - 4);
        for (uint256 i; i < tail.length; ++i) tail[i] = ret[i + 4];
        return keccak256(bytes(abi.decode(tail, (string))));
    }

    function _contains(bytes memory hay, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        if (hay.length < n.length) return false;
        for (uint256 i; i + n.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) if (hay[i + j] != n[j]) { m = false; break; }
            if (m) return true;
        }
        return false;
    }

    function _tryOpen(address user, bool short, uint256 marginUsdc) internal returns (bool ok, bytes memory ret, uint256 id) {
        uint256 shares = _marginPTokens(user, marginUsdc);
        IsolatedMarginExecutorUpgradeable.OpenParams memory p;
        (p,) = _openParams(short, shares, MAX_LEV_X100);
        vm.prank(user);
        (ok, ret) = address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, p));
        if (ok) id = abi.decode(ret, (uint256));
    }

    // ================================================================= margin OPEN is subject to the floor
    function testMarginOpen_RespectsTheFloor_BothDirections() public {
        mConfig.queueFundedLiquidator(FUNDER);
        _activate();

        // LONG: the debt is borrowed from pUSDC
        uint256 cash0 = pUsdc.getCash();
        (bool ok,, uint256 idA) = _tryOpen(ALICE, false, 5_000e6);
        assertTrue(ok, "control: a long opens with the floor disabled");
        uint256 usedUsdc = cash0 - pUsdc.getCash();
        assertGt(usedUsdc, 0, "the open removed cash from pUSDC");
        uint256 snap = vm.snapshotState();
        uint256 cashNow = pUsdc.getCash();
        // a floor that the next identical open would breach by exactly 1 unit
        _setFloor(pUsdc, cashNow - usedUsdc + 1);
        bytes memory ret;
        (ok, ret,) = _tryOpen(BOB, false, 5_000e6);
        assertFalse(ok, "open that would leave pUSDC cash 1 unit under the floor is rejected");
        assertTrue(_contains(ret, "borrow cash floor"), "rejected by the floor");
        vm.revertToState(snap);
        // a floor that the next identical open meets exactly
        _setFloor(pUsdc, cashNow - usedUsdc);
        (ok,,) = _tryOpen(BOB, false, 5_000e6);
        assertTrue(ok, "open leaving cash exactly at the floor is allowed");
        idA;
        vm.revertToState(snap);

        // SHORT: the debt is borrowed from pWAVAX
        uint256 wcash0 = pWavax.getCash();
        uint256 idS;
        (ok,, idS) = _tryOpen(ALICE, true, 5_000e6);
        assertTrue(ok, "control: a short opens with the floor disabled");
        uint256 usedWavax = wcash0 - pWavax.getCash();
        assertGt(usedWavax, 0);
        uint256 snap2 = vm.snapshotState();
        uint256 wcashNow = pWavax.getCash();
        _setFloor(pWavax, wcashNow - usedWavax + 1);
        (ok, ret,) = _tryOpen(BOB, true, 5_000e6);
        assertFalse(ok, "short open 1 unit under the floor is rejected");
        assertTrue(_contains(ret, "borrow cash floor"));
        vm.revertToState(snap2);
        _setFloor(pWavax, 0);
        // already below the floor (floor above current cash)
        _setFloor(pWavax, wcashNow + 1);
        (ok, ret,) = _tryOpen(BOB, true, 1_000e6);
        assertFalse(ok, "already below the floor: rejected");
        idS;
    }

    // ================================================================= margin EXITS are unchanged below the floor
    struct Res { bool ok; uint256 debt; uint8 status; }

    function _res(bool ok, uint256 id) internal view returns (Res memory r) {
        r.ok = ok;
        r.debt = _debtOf(id);
        r.status = uint8(_position(id).status);
    }

    function _equal(Res memory a, Res memory b, string memory why) internal pure {
        assertEq(a.ok, b.ok, string.concat(why, ": success"));
        assertEq(a.debt, b.debt, string.concat(why, ": debt"));
        assertEq(a.status, b.status, string.concat(why, ": status"));
    }

    function _floorsAboveCash(bool on) internal {
        _setFloor(pUsdc, on ? pUsdc.getCash() + 1 : 0);
        _setFloor(pWavax, on ? pWavax.getCash() + 1 : 0);
    }

    function _fundedParams(uint256 id) internal pure returns (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory) {
        return IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, KEEPER_RECIPIENT, type(uint256).max, 0, 0, 0);
    }

    function testMarginExits_UnchangedBelowTheFloor() public {
        mConfig.queueFundedLiquidator(FUNDER);
        _activate();
        mConfig.addFundedLiquidator(FUNDER);
        (, , uint256 idClose) = _tryOpen(ALICE, false, 5_000e6);
        (, , uint256 idFlash) = _tryOpen(BOB, false, 5_000e6);
        (, , uint256 idFunded) = _tryOpen(DAVE, false, 5_000e6);
        (, , uint256 idShort) = _tryOpen(LP, true, 5_000e6);
        assertTrue(idClose != 0 && idFlash != 0 && idFunded != 0 && idShort != 0);
        uint256 s0 = vm.snapshotState();

        // (a) voluntary close, long and short, with cash below the floor
        Res[2] memory c;
        for (uint256 p; p < 2; ++p) {
            _floorsAboveCash(p == 0);
            (bool ok,) = _close(ALICE, idClose, 10_000);
            c[p] = _res(ok, idClose);
            vm.revertToState(s0);
        }
        _equal(c[0], c[1], "close (long)");
        assertTrue(c[0].ok, "close succeeds");
        for (uint256 p; p < 2; ++p) {
            _floorsAboveCash(p == 0);
            (bool ok,) = _close(LP, idShort, 10_000);
            c[p] = _res(ok, idShort);
            vm.revertToState(s0);
        }
        _equal(c[0], c[1], "close (short)");

        // (b) flash liquidation of a long after a price shock
        Res[2] memory f;
        for (uint256 p; p < 2; ++p) {
            _setAvaxBps(6_300);
            _floorsAboveCash(p == 0);
            (bool ok,) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidate, (_liqParams(idFlash))));
            f[p] = _res(ok, idFlash);
            vm.revertToState(s0);
            vm.clearMockedCalls();
            _setAvaxBps(10_000);
        }
        _equal(f[0], f[1], "flash liquidation");
        assertTrue(f[0].ok, "flash liquidation succeeds below the floor");

        // (c) funded in-kind liquidation
        Res[2] memory u;
        for (uint256 p; p < 2; ++p) {
            _setAvaxBps(6_300);
            _floorsAboveCash(p == 0);
            IsolatedMarginTypes.Position memory pos = _position(idFunded);
            uint256 owed = PErc20(pos.debtPToken).borrowBalanceCurrent(pos.account);
            address asset = PErc20(pos.debtPToken).underlying();
            deal(asset, FUNDER, owed * 2 + 1);
            vm.prank(FUNDER);
            IERC20(asset).approve(address(liquidator), type(uint256).max);
            vm.prank(FUNDER);
            (bool ok,) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (_fundedParams(idFunded))));
            u[p] = _res(ok, idFunded);
            vm.revertToState(s0);
            vm.clearMockedCalls();
            _setAvaxBps(10_000);
        }
        _equal(u[0], u[1], "funded liquidation");
        assertTrue(u[0].ok, "funded liquidation succeeds below the floor");
    }
}
