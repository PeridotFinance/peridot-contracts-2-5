// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

contract AnyContractToken {}

/**
 * @notice The OPT-IN no-reward-token constructor of the PRODUCTION `PeridottrollerAvalanche` (reviewable diff, not merged).
 *         Default guard preserved byte-for-byte (same revert string); `address(0)` only with the explicit flag; claimPeridot and
 *         _grantPeridot revert with no token; every lending path (and the borrow cash floor) passes.
 */
contract AvalancheRewardTokenOptInForkTest is AvalancheCashOnlyBase {
    function _switchTo(address impl) internal {
        require(unitroller._setPendingImplementation(impl) == 0, "pending");
        (bool ok,) = impl.call(abi.encodeWithSignature("_become(address)", address(unitroller)));
        require(ok, "become");
    }

    // ---------------------------------------------------------------- the guard: default preserved, opt-in explicit
    function testDefaultGuard_ZeroWithoutTheFlagIsRefused_NoSilentFallback_SameRevertString() public {
        vm.expectRevert(bytes("AvalancheController: token not contract"));
        new PeridottrollerAvalanche(address(0), false);
    }

    function testFlagDoesNotExcuseANonZeroAddressWithoutCode() public {
        vm.expectRevert(bytes("AvalancheController: token not contract"));
        new PeridottrollerAvalanche(address(0xE0A), true);
        vm.expectRevert(bytes("AvalancheController: token not contract"));
        new PeridottrollerAvalanche(address(0xE0A), false);
    }

    function testRealTokenBehavesAsBefore_FlagIrrelevant() public {
        address tok = address(new AnyContractToken());
        PeridottrollerAvalanche a = new PeridottrollerAvalanche(tok, false);
        PeridottrollerAvalanche b = new PeridottrollerAvalanche(tok, true);
        assertEq(a.getPeridotAddress(), tok);
        assertEq(b.getPeridotAddress(), tok);
        assertEq(a.peridotToken(), tok);
        assertEq(b.peridotToken(), tok);
    }

    function testOptInAcceptsZero() public {
        PeridottrollerAvalanche p = new PeridottrollerAvalanche(address(0), true);
        assertEq(p.getPeridotAddress(), address(0));
        assertEq(p.peridotToken(), address(0));
    }

    function testChainIdGateStillAppliesWithTheOptIn() public {
        vm.chainId(43_113);
        vm.expectRevert(bytes("AvalancheController: Avalanche only"));
        new PeridottrollerAvalanche(address(0), true);
    }

    // ---------------------------------------------------------------- behaviour with the opt-in controller
    function _lendingPaths() internal {
        _unpauseBorrows();
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.4e18) == 0, "cf");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u");
        uint256 pw = _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 300e6);
        assertTrue(ok, "borrow");
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 86_400);
        _setAvaxBps(10_000);
        (ok,) = _repay(pUsdc, DAVE, 50e6);
        assertTrue(ok, "repay");
        vm.prank(DAVE);
        assertTrue(pWavax.transfer(CAROL, pw / 20), "transfer claim");
        _setAvaxBps(5_000);
        (bool lok,,) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        assertTrue(lok, "liquidation + seize");
        uint256 claim = pWavax.balanceOf(CAROL);
        (ok,) = _redeemUnderlying(pWavax, CAROL, Math.mulDiv(claim, pWavax.exchangeRateStored(), 1e18) / 2);
        assertTrue(ok, "redeem");
        _setAvaxBps(10_000);
        (ok,) = _repay(pUsdc, DAVE, type(uint256).max);
        assertTrue(ok, "full repay");
    }

    function testOptInController_EveryLendingPathPasses_ClaimAndGrantRevert() public {
        _switchTo(address(new PeridottrollerAvalanche(address(0), true)));
        assertEq(controller.getPeridotAddress(), address(0));
        assertEq(controller.peridotSupplySpeeds(address(pUsdc)), 0);
        assertEq(controller.peridotBorrowSpeeds(address(pUsdc)), 0);
        _lendingPaths();
        (bool ok,) = address(controller).call(abi.encodeWithSignature("claimPeridot(address)", DAVE));
        assertFalse(ok, "claimPeridot reverts with no reward token");
        // _grantPeridot as the ADMIN (this test contract), so the revert is not an authorization failure
        (ok,) = address(controller).call(abi.encodeWithSignature("_grantPeridot(address,uint256)", DAVE, 1));
        assertFalse(ok, "_grantPeridot reverts with no reward token (called by the admin)");
    }

    function testOptInController_BorrowCashFloorStillEnforced() public {
        _switchTo(address(new PeridottrollerAvalanche(address(0), true)));
        _unpauseBorrows();
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.4e18) == 0, "cf");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u");
        PeridottrollerAvalanche ctrl = PeridottrollerAvalanche(address(controller));
        uint256 cash = pUsdc.getCash();
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), cash - 100e6) == 0, "floor");
        _mintP(pWavax, DAVE, 100_000e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 100e6 + 1);
        assertFalse(ok, "one unit beyond the floor refused");
        (ok,) = _borrow(pUsdc, DAVE, 100e6);
        assertTrue(ok, "within the floor");
    }

    function testRealTokenController_LendingPathsPass() public {
        // the production-shaped controller (explicit contract token) is unaffected: lending paths pass
        address tok = address(new AnyContractToken());
        _switchTo(address(new PeridottrollerAvalanche(tok, false)));
        assertEq(controller.getPeridotAddress(), tok);
        _lendingPaths();
    }
}
