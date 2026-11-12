// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/// @dev A contract with code that REVERTS ON ANY CALL (no functions, no fallback): stands in for "a token that must never be touched".
contract RevertsOnAnyCall {}

/// @dev TEST-ONLY controller variant with NO reward token at all (`getPeridotAddress()` = address(0)): shows what a pilot without any
///      PERIDOT dependency would look like. Not a proposed contract.
contract TestOnlyControllerNoRewardToken is Peridottroller {
    function getPeridotAddress() public pure override returns (address) {
        return address(0);
    }
}

/**
 * @notice Why `PeridottrollerAvalanche` needs a PERIDOT token address, and whether a NO-INCENTIVE pilot (all reward speeds zero) can
 *         operate without any token dependency. Method: swap the live controller implementation (the Unitroller supports it) to variants
 *         whose reward token reverts on every call or does not exist, and run every lending path of the pilot.
 */
contract AvalancheCashOnlyRewardTokenIndependenceForkTest is AvalancheCashOnlyBase {
    function _switchTo(address impl) internal {
        require(unitroller._setPendingImplementation(impl) == 0, "pending");
        (bool ok,) = impl.call(abi.encodeWithSignature("_become(address)", address(unitroller)));
        require(ok, "become");
    }

    /// @dev every pilot path, in one pass; returns nothing, reverts if any path touches a broken token
    function _lendingPaths() internal {
        _unpauseBorrows();
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.4e18) == 0, "cf");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u");
        uint256 pw = _mintP(pWavax, DAVE, 100e18); // supply
        _enter(DAVE); // enter markets
        (bool ok,) = _borrow(pUsdc, DAVE, 300e6); // borrow
        assertTrue(ok, "borrow");
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 86_400);
        _setAvaxBps(10_000);
        (ok,) = _repay(pUsdc, DAVE, 50e6); // repay (accrues interest)
        assertTrue(ok, "repay");
        vm.prank(DAVE);
        assertTrue(pWavax.transfer(CAROL, pw / 20), "transfer claim");
        _setAvaxBps(5_000); // gap
        (bool lok,,) = _liquidate(pUsdc, pWavax, DAVE, 100e6); // liquidation + seize
        assertTrue(lok, "liquidation");
        uint256 carolClaim = pWavax.balanceOf(CAROL);
        (ok,) = _redeemUnderlying(pWavax, CAROL, Math.mulDiv(carolClaim, pWavax.exchangeRateStored(), 1e18) / 2); // redeem seized claim
        assertTrue(ok, "redeem");
        _setAvaxBps(10_000);
        (ok,) = _repay(pUsdc, DAVE, type(uint256).max);
        // exit markets after repaying everything
        vm.prank(BOB);
        controller.exitMarket(address(pUsdc));
    }

    function testLendingPaths_NeverTouchTheRewardToken_TokenThatRevertsOnAnyCall() public {
        address revertToken = address(new RevertsOnAnyCall());
        _switchTo(address(new PeridottrollerAvalanche(revertToken, false)));
        assertEq(controller.getPeridotAddress(), revertToken);
        assertEq(controller.peridotSupplySpeeds(address(pUsdc)), 0, "no supply reward speed");
        assertEq(controller.peridotBorrowSpeeds(address(pUsdc)), 0, "no borrow reward speed");
        _lendingPaths(); // would revert if any lending path called the token
        // the ONLY entry points that touch the token are claimPeridot / _grantPeridot: with this token they revert
        (bool ok,) = address(controller).call(abi.encodeWithSignature("claimPeridot(address)", DAVE));
        assertFalse(ok, "claimPeridot calls the token (balanceOf) and therefore reverts with a token that reverts");
    }

    function testLendingPaths_WithNoRewardTokenAtAll_AddressZero() public {
        _switchTo(address(new TestOnlyControllerNoRewardToken()));
        assertEq(controller.getPeridotAddress(), address(0));
        _lendingPaths(); // supply, enter, borrow, repay, transfer, liquidate, seize, redeem, exit: all work with NO token
        (bool ok,) = address(controller).call(abi.encodeWithSignature("claimPeridot(address)", DAVE));
        assertFalse(ok, "claimPeridot reverts with no token (nothing to claim in a no-incentive pilot)");
        (ok,) = address(controller).call(abi.encodeWithSignature("_grantPeridot(address,uint256)", DAVE, 1));
        assertFalse(ok, "and so does _grantPeridot (admin only)");
    }

    function testHardcodedBaseTokenAddress_HasNoCodeOnAvalanche() public view {
        // `Peridottroller.getPeridotAddress()` hardcodes this address (another chain's token). On Avalanche it is NOT a contract, which is
        // why the Avalanche wrapper forces an explicit choice instead of inheriting it.
        assertEq(address(0x507f0F5E58d21f07d133722e038067248fe4ecBE).code.length, 0, "no code at the base's hardcoded address on Avalanche");
    }
}
