// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PharaohDlmmShareOracle} from "../../contracts/PharaohDlmmShareOracle.sol";
import {TokenErrorReporter} from "../../contracts/ErrorReporter.sol";
import {BpBase} from "./BpBase.sol";

/// @dev Calls `poke()` n times inside ONE transaction (the compounding attempt).
contract BpPokeProbe {
    function pokeMany(PharaohDlmmShareOracle w, uint256 n) external returns (bool[] memory r) {
        r = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = w.poke();
        }
    }
}

/// @notice Wrapper v2 (PharaohDlmmShareOracle with the 97% / 24 h stale fallback) at STACK level: real controller, real pTokens, real
///         guarded oracle. Two different outages are distinguished throughout:
///           (a) VAULT-side outage: `vault.setConvertReverts(true)` with the base USDC feed fresh. Served by the fallback: price =
///               lastGood x 97% x live USDC, for at most 24 h after the last poke (exactly valid at age == 24 h).
///           (b) BASE USDC feed stale (`_staleUsdcFeedAt`): the share is priced 0 AND pUSDC is priced 0 by the guarded oracle itself, so
///               every pUSDC debtor is frozen regardless of the wrapper (PRE-EXISTING, independent of the wrapper).
///         Foundry 1.7.1 caches `block.timestamp` after `vm.warp` inside one function: every test keeps explicit timestamp variables
///         (`t0` = the wrapper's last good time, set at construction) and `_at(ts, avax8)` re-pins the base feeds at `ts`.
contract BpStaleFallbackTest is BpBase {
    address internal constant DAVE = address(0xDA7E);
    address internal constant EVE = address(0xE5E);
    address internal constant FRANK = address(0xF7A);

    uint256 internal constant WINDOW = 24 hours;
    uint256 internal t0; // wrapper.lastGoodTime() right after deployment

    function setUp() public override {
        super.setUp();
        _listShareMarket(); // CF 0, borrow paused, cap 1, seeded; wrapper installed
        t0 = wrapper.lastGoodTime();
    }

    // ------------------------------------------------------------------------------------------------ helpers
    function _raiseCf() internal {
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "cf 50%");
    }

    function _cf(address m) internal view returns (uint256 cf) {
        (, cf,) = controller.markets(m);
    }

    /// @dev Moves the clock to `ts` and pins both base feeds fresh there (AVAX answer `avax8`). The VAULT is not touched.
    function _at(uint256 ts, int256 avax8) internal {
        vm.warp(ts);
        _pinFeeds(ts, avax8);
    }

    /// @dev pWAVAX collateral, 10 USDC borrowed, and the account ENTERS bp with a ZERO share balance (free): the contagion case.
    function _contagionDebtor(address who) internal {
        _mintUnderlyingP(pWavax, who, 10e18);
        _enter(who, address(pWavax));
        (bool ok,) = _borrowUsdc(who, 10e6);
        assertTrue(ok, "setup borrow");
        _enter(who, address(bp));
        assertEq(bp.balanceOf(who), 0, "zero share balance");
        assertTrue(controller.checkMembership(who, PToken(address(bp))));
    }

    /// @dev pWAVAX-only debtor that NEVER enters bp.
    function _plainDebtor(address who) internal {
        _mintUnderlyingP(pWavax, who, 10e18);
        _enter(who, address(pWavax));
        (bool ok,) = _borrowUsdc(who, 10e6);
        assertTrue(ok, "setup borrow");
    }

    function _liqCode(bool ok, bytes memory ret) internal pure returns (uint256) {
        return ok ? abi.decode(ret, (uint256)) : type(uint256).max;
    }

    /// @dev `repay` of `who`'s USDC debt by CAROL, seizing pWAVAX. Asserts liquidateBorrow returned 0 and that the repaid and seized amounts
    ///      are exactly what the controller computes (incentive 108%, protocol seize share 2.8%).
    function _liquidateAndCheck(address who, uint256 repay) internal {
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(who);
        (uint256 e, uint256 seize) = controller.liquidateCalculateSeizeTokens(address(pUsdc), address(pWavax), repay);
        assertEq(e, 0, "seize calc");
        assertGt(seize, 0);
        uint256 protocol = (seize * PROTOCOL_SEIZE_SHARE) / 1e18;
        uint256 whoBefore = pWavax.balanceOf(who);
        uint256 carolBefore = pWavax.balanceOf(CAROL);
        uint256 usdcBefore = usdc.balanceOf(CAROL);

        (bool ok, bytes memory ret) = _liquidateSeizing(CAROL, who, repay, address(pWavax));
        assertTrue(ok, string(abi.encodePacked("liquidate reverted: code ", vm.toString(_errCode(ret)))));
        assertEq(abi.decode(ret, (uint256)), 0, "liquidateBorrow returns 0 (NO_ERROR)");
        assertEq(usdc.balanceOf(CAROL), usdcBefore, "liquidator paid exactly the repay");
        assertEq(debtBefore - pUsdc.borrowBalanceStored(who), repay, "debt fell by exactly the repay");
        assertEq(whoBefore - pWavax.balanceOf(who), seize, "borrower lost exactly the seize");
        assertEq(pWavax.balanceOf(CAROL) - carolBefore, seize - protocol, "liquidator got the seize less the protocol share");
    }

    function _assertFrozenLiquidation(address who, string memory tag) internal {
        (bool ok, bytes memory ret) = _liquidateSeizing(CAROL, who, 2e6, address(pWavax));
        assertFalse(ok, string.concat("no liquidation: ", tag));
        assertEq(_selector(ret), TokenErrorReporter.LiquidatePeridottrollerRejection.selector, tag);
        assertEq(_errCode(ret), ERR_PRICE, tag);
    }

    // ================================================================ 1. contagion account stays liquidatable inside the window
    function test_contagion_liquidatableDuringVaultOutage_at1h() external {
        _contagionDebtor(DAVE);
        vault.setConvertReverts(true);
        uint256 ts = t0 + 1 hours;
        _at(ts, 1e8); // AVAX $1: DAVE deeply underwater
        (, , , bool usingFallback, uint256 left) = wrapper.shareState();
        assertTrue(usingFallback);
        assertEq(left, WINDOW - 1 hours);
        assertEq(_price(PToken(address(bp))), 0.97e30, "fallback price");
        (uint256 err, , uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertEq(err, 0, "no PRICE_ERROR for the zero-balance entrant");
        assertGt(shortfall, 0);
        _liquidateAndCheck(DAVE, 2e6);
    }

    function test_contagion_liquidatableDuringVaultOutage_atExactly24h() external {
        _contagionDebtor(DAVE);
        vault.setConvertReverts(true);
        uint256 ts = t0 + WINDOW; // age == 24 h: still valid
        _at(ts, 1e8);
        (, , , bool usingFallback, uint256 left) = wrapper.shareState();
        assertTrue(usingFallback, "valid at age == 24h");
        assertEq(left, 0, "no seconds left, but still valid");
        assertEq(_price(PToken(address(bp))), 0.97e30);
        _liquidateAndCheck(DAVE, 2e6);
    }

    // ================================================================ 2. one second later: frozen; recovery by poke
    function test_contagion_frozenOneSecondAfterWindow() external {
        _contagionDebtor(DAVE);
        vault.setConvertReverts(true);
        uint256 ts = t0 + WINDOW + 1;
        _at(ts, 1e8);
        (, , , bool usingFallback, uint256 left) = wrapper.shareState();
        assertFalse(usingFallback);
        assertEq(left, 0);
        assertEq(_price(PToken(address(bp))), 0, "expired: unpriced");
        assertEq(wrapper.getShareUsdPrice(), 0);
        (uint256 err,,) = controller.getAccountLiquidity(DAVE);
        assertEq(err, ERR_PRICE, "controller PRICE_ERROR = 13");
        _assertFrozenLiquidation(DAVE, "one second after the window");
        // the same freeze for a pWAVAX redeem of the entered account, and for a plain debtor that never entered bp: NOT frozen
        (bool ok, bytes memory ret) = _try(DAVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1));
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE);
        _plainDebtorAfterWarp(EVE, ts);
    }

    /// @dev a debtor that never entered bp is still liquidatable at the same moment (EVE enters pWAVAX and borrows at the new timestamp
    ///      with fresh AVAX $20 first, then AVAX crashes).
    function _plainDebtorAfterWarp(address who, uint256 ts) internal {
        _pinFeeds(ts, 20e8);
        _plainDebtor(who);
        _pinFeeds(ts, 1e8);
        (bool ok,) = _liquidateSeizing(CAROL, who, 2e6, address(pWavax));
        assertTrue(ok, "debtor that never entered bp is liquidatable");
    }

    function test_pokeWhileVaultDown_returnsFalse_andDoesNotExtendTheWindow() external {
        _contagionDebtor(DAVE);
        vault.setConvertReverts(true);
        uint256 tNear = t0 + 23 hours;
        _at(tNear, 1e8);
        assertFalse(wrapper.poke(), "vault cannot answer: nothing stored");
        assertEq(wrapper.lastGoodTime(), t0, "window not extended");
        assertEq(wrapper.lastGoodAssetsPerShare(), 1e6);
        uint256 tExp = t0 + WINDOW + 1;
        _at(tExp, 1e8);
        assertFalse(wrapper.poke(), "still down after the window");
        assertEq(wrapper.lastGoodTime(), t0);
        assertEq(_price(PToken(address(bp))), 0, "the failed poke did not revive the fallback");
        _assertFrozenLiquidation(DAVE, "poked while down");
    }

    function test_recovery_liquidatableAgainImmediatelyAfterSuccessfulPoke() external {
        _contagionDebtor(DAVE);
        vault.setConvertReverts(true);
        uint256 tExp = t0 + WINDOW + 1;
        _at(tExp, 1e8);
        _assertFrozenLiquidation(DAVE, "frozen first");

        vault.setConvertReverts(false); // the vault answers again: the LIVE price needs no poke
        (uint256 err, , uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertEq(err, 0);
        assertGt(shortfall, 0, "liquidatable on the live price even before a poke");

        assertTrue(wrapper.poke(), "window over: the live value is stored whatever it is");
        assertEq(wrapper.lastGoodTime(), tExp);
        assertEq(wrapper.lastGoodAssetsPerShare(), 1e6);
        (, , , bool usingFallback, uint256 left) = wrapper.shareState();
        assertFalse(usingFallback, "vault answers: live price, no fallback");
        assertEq(left, WINDOW, "a fresh 24 h window");
        _liquidateAndCheck(DAVE, 2e6);

        // a second outage starts a NEW window measured from the poke
        vault.setConvertReverts(true);
        uint256 tLater = tExp + WINDOW;
        _at(tLater, 1e8);
        assertEq(_price(PToken(address(bp))), 0.97e30, "inside the new window");
        _liquidateAndCheck(DAVE, 1e6);
        uint256 tOver = tExp + WINDOW + 1;
        _at(tOver, 1e8);
        assertEq(_price(PToken(address(bp))), 0, "and over again one second later");
        _assertFrozenLiquidation(DAVE, "second window over");
    }

    // ================================================================ 3. borrow / redeem during the fallback use 97% of the last good leg
    function test_fallbackBorrowLimit_is97PercentOfTheLastGoodLeg() external {
        _raiseCf();
        _supplyShares(ALICE, 100e6);
        _enter(ALICE, address(bp));
        // last good leg = 0.8 (a LOWER value is stored at once by poke)
        vault.setAssetsPerWholeShare(0.8e6);
        assertTrue(wrapper.poke());
        assertEq(wrapper.lastGoodAssetsPerShare(), 0.8e6);
        vault.setConvertReverts(true);
        uint256 ts = t0 + 6 hours;
        _at(ts, 20e8);
        assertEq(_price(PToken(address(bp))), 0.776e30, "0.97 x 0.8 x $1");

        (uint256 err, uint256 liquidity, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        assertEq(shortfall, 0);
        assertEq(liquidity, 38.8e18, "100 shares x 0.776 x CF 50% = $38.8");
        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 38.8e6 + 1);
        assertFalse(ok, "one base unit over the 97% limit");
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY);
        (ok,) = _borrowUsdc(ALICE, 38.8e6);
        assertTrue(ok, "exactly the 97% limit borrows");
    }

    function test_fallbackRedeem_byEnteredAccount_isCheckedAt97Percent() external {
        _raiseCf();
        _openBorrow(ALICE, 100e6, 30e6); // entered, 30 USDC debt, live price 1.0
        _supplyShares(BOB, 100e6);
        _enter(BOB, address(bp)); // entered, no debt
        vault.setConvertReverts(true);
        assertEq(_price(PToken(address(bp))), 0.97e30);

        // BOB (no debt) redeems everything while entered: works while the fallback is valid
        uint256 bobTokens = bp.balanceOf(BOB);
        (bool ok,) = _redeemShares(BOB, bobTokens);
        assertTrue(ok, "debt-free entered account redeems all during the fallback");
        assertEq(vault.balanceOf(BOB), 100e6);

        // ALICE: remaining shares s must satisfy s x 0.97 x 50% >= 30  =>  s >= 61.86
        (bytes memory ret) = _redeemRet(ALICE, 39e6 * 5000); // leaves 61 shares: 61 x 0.485 = 29.585 < 30
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY, "redeem below the 97% requirement refused");
        (ok,) = _redeemShares(ALICE, 38e6 * 5000); // leaves 62 shares: 30.07 >= 30
        assertTrue(ok, "redeem inside the 97% requirement works");
        assertEq(bp.balanceOf(ALICE), 62e6 * 5000);
    }

    function _redeemRet(address who, uint256 pTokens) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = _redeemShares(who, pTokens);
        assertFalse(ok);
    }

    /// @dev DOCUMENTED CONSEQUENCE of the haircut: a borrower at the 50% maximum on the live price is liquidatable once the fallback
    ///      prices the shares 3% lower ($48.5 of power against a $50 debt). It is liquidatable (not frozen); the liquidator is paid at
    ///      the 97% price.
    function test_fallback_atMaxBorrowerBecomesLiquidatableAt97Percent() external {
        _raiseCf();
        _openBorrow(ALICE, 100e6, 50e6); // the 50% maximum at price 1.0
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(shortfall, 0);
        vault.setConvertReverts(true);
        (uint256 err, , uint256 shortfall97) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        assertEq(shortfall97, 1.5e18, "50 - 48.5");
        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, 25e6);
        assertTrue(ok, string(abi.encodePacked("liquidate: code ", vm.toString(_errCode(ret)))));
        assertEq(abi.decode(ret, (uint256)), 0);
        // seize = 25 USDC x 1.08 / 0.97 shares, in pTokens (the controller's Exp arithmetic, re-derived)
        uint256 numerator = (INCENTIVE * 1e30) / 1e18;
        uint256 denominator = (0.97e30 * 2e14) / 1e18;
        uint256 expected = (((numerator * 1e18) / denominator) * 25e6) / 1e18;
        assertEq(bp.balanceOf(ALICE), 100e6 * 5000 - expected, "seized at the 97% price");
    }

    // ================================================================ 4. BASE USDC feed outage: unchanged, with and without the wrapper
    struct Outcome {
        uint256 accErr;
        bool liqOk;
        uint256 liqCode;
        bool redeemOk;
        uint256 redeemCode;
        bool borrowOk;
        uint256 borrowCode;
    }

    function _code(bool ok, bytes memory ret) internal pure returns (uint256) {
        return ok ? 0 : _errCode(ret);
    }

    /// @dev Everything an account can try against pWAVAX / pUSDC, measured inside a snapshot (state is restored).
    function _measure(address who) internal returns (Outcome memory o) {
        uint256 snap = vm.snapshotState();
        (o.accErr,,) = controller.getAccountLiquidity(who);
        bytes memory ret;
        (o.liqOk, ret) = _liquidateSeizing(FRANK, who, 2e6, address(pWavax));
        o.liqCode = _code(o.liqOk, ret);
        (o.redeemOk, ret) = _try(who, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e8));
        o.redeemCode = _code(o.redeemOk, ret);
        (o.borrowOk, ret) = _borrowUsdc(who, 1e6);
        o.borrowCode = _code(o.borrowOk, ret);
        vm.revertToState(snap);
    }

    function _assertSameOutcome(Outcome memory a, Outcome memory b, string memory tag) internal pure {
        assertEq(a.accErr, b.accErr, string.concat(tag, ": liquidity error"));
        assertEq(a.liqOk, b.liqOk, string.concat(tag, ": liquidation ok"));
        assertEq(a.liqCode, b.liqCode, string.concat(tag, ": liquidation code"));
        assertEq(a.redeemOk, b.redeemOk, string.concat(tag, ": redeem ok"));
        assertEq(a.redeemCode, b.redeemCode, string.concat(tag, ": redeem code"));
        assertEq(a.borrowOk, b.borrowOk, string.concat(tag, ": borrow ok"));
        assertEq(a.borrowCode, b.borrowCode, string.concat(tag, ": borrow code"));
    }

    /// @dev World 0 = the guarded oracle ALONE (controller.oracle() = old, nobody has entered bp). World 1 = wrapper installed, DAVE
    ///      entered bp with a zero balance. With the BASE USDC feed stale (a) pUSDC is priced 0 by the guarded oracle in BOTH worlds and
    ///      (b) every pUSDC debtor gets the identical outcome in both worlds (PRICE_ERROR 13 for liquidation, redeem and borrow), and an
    ///      account that never entered bp is identical too. Run with the vault healthy and with the vault ALSO down.
    function _compareWorlds(bool vaultDownToo, string memory tag) internal {
        _plainDebtor(DAVE); // pUSDC debtor (will enter bp in world 1)
        _plainDebtor(EVE); // pUSDC debtor that never enters bp
        _mintUnderlyingP(pWavax, FRANK, 10e18); // debt-free pWAVAX supplier that never enters bp (also the liquidator, uses no balance)
        _enter(FRANK, address(pWavax));
        avaxFeed.setRound(1e8, block.timestamp, 9, 9); // AVAX $1: both debtors underwater on a fresh feed
        _staleUsdcFeed();
        if (vaultDownToo) vault.setConvertReverts(true);

        // ---- world 0: guarded oracle alone (setUp listed bp and installed the wrapper; step back to the old oracle. Nobody has entered bp
        // yet, and the controller prices only the markets in an account's list, so for these accounts this IS the pre-listing behaviour)
        require(controller._setPriceOracle(PriceOracle(address(old))) == 0);
        assertEq(address(controller.oracle()), address(old));
        assertEq(old.getUnderlyingPrice(PToken(address(pUsdc))), 0, "guarded oracle: pUSDC unpriced on a stale USDC feed");
        Outcome memory d0 = _measure(DAVE);
        Outcome memory e0 = _measure(EVE);
        Outcome memory f0 = _measure(FRANK);
        assertEq(d0.accErr, ERR_PRICE, "pUSDC debtor frozen by the guarded oracle alone (pre-existing)");
        assertFalse(d0.liqOk);
        assertEq(d0.liqCode, ERR_PRICE);
        assertFalse(d0.borrowOk);
        assertEq(f0.accErr, 0, "an account with no pUSDC exposure is not affected");
        assertTrue(f0.redeemOk);

        // ---- world 1: bp listed, wrapper installed, DAVE enters bp (zero balance)
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0);
        _enter(DAVE, address(bp));
        avaxFeed.setRound(1e8, block.timestamp, 9, 9);
        _staleUsdcFeed();
        assertEq(address(controller.oracle()), address(wrapper));
        assertEq(wrapper.getUnderlyingPrice(PToken(address(pUsdc))), 0, "wrapper: pUSDC identical (0)");
        assertEq(_price(PToken(address(bp))), 0, "share priced 0 on the stale BASE feed, vault up or down");
        assertEq(wrapper.getShareUsdPrice(), 0);
        (, , , bool usingFallback,) = wrapper.shareState();
        assertFalse(usingFallback, string.concat(tag, ": no fallback when the BASE USDC price is unavailable"));
        Outcome memory d1 = _measure(DAVE);
        Outcome memory e1 = _measure(EVE);
        _assertSameOutcome(d0, d1, string.concat(tag, " pUSDC debtor that entered bp"));
        _assertSameOutcome(e0, e1, string.concat(tag, " pUSDC debtor that never entered bp"));

        // ---- no new exposure: nobody can borrow USDC against shares (or anything) on a stale USDC feed
        _freshUsdcFeed();
        _raiseCf(); // CF 50% (accepted: the share is priced while the base feed is fresh)
        _staleUsdcFeed();
        _supplyShares(ALICE, 100e6);
        _enter(ALICE, address(bp));
        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 1e6);
        assertFalse(ok, "no borrow against shares while the BASE feed is stale");
        assertEq(_errCode(ret), ERR_PRICE);
    }

    function test_baseUsdcFeedOutage_sameFreezeWithAndWithoutWrapper_vaultUp() external {
        _compareWorlds(false, "vault up");
    }

    function test_baseUsdcFeedOutage_sameFreezeWithAndWithoutWrapper_vaultAlsoDown() external {
        _compareWorlds(true, "vault down");
    }

    /// @dev What the wrapper DOES add on a stale BASE USDC feed, stated precisely: an account that entered bp but has NO pUSDC debt or
    ///      pUSDC entry is frozen (PRICE_ERROR) in every market for the duration of the BASE feed outage, because the share is priced 0
    ///      (shares are valued in USDC) and the controller refuses to compute liquidity with a price-0 asset in the account's list. Without
    ///      bp listed the same account is NOT frozen. It is limited to accounts that chose to enter bp; pUSDC debtors are frozen anyway.
    function test_baseUsdcFeedOutage_bpEntrantWithoutUsdcExposure_isFrozen_whileOthersAreNot() external {
        _mintUnderlyingP(pWavax, EVE, 10e18); // pWAVAX supplier, no debt, never enters bp
        _enter(EVE, address(pWavax));
        _mintUnderlyingP(pWavax, DAVE, 10e18); // pWAVAX supplier, no debt, enters bp (zero balance)
        _enter(DAVE, address(pWavax));
        _enter(DAVE, address(bp));
        _staleUsdcFeed();
        (uint256 err,,) = controller.getAccountLiquidity(EVE);
        assertEq(err, 0, "never entered bp: not frozen");
        (bool ok,) = _try(EVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e8));
        assertTrue(ok);
        (err,,) = controller.getAccountLiquidity(DAVE);
        assertEq(err, ERR_PRICE, "entered bp (listed): frozen while the BASE USDC feed is stale");
        bytes memory ret;
        (ok, ret) = _try(DAVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e8));
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE);
        // it ends with the outage
        _freshUsdcFeed();
        (ok,) = _try(DAVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e8));
        assertTrue(ok, "unfrozen when the feed is fresh again");
    }

    // ================================================================ 5. _setCollateralFactor and the R1 rollback during the fallback
    function test_setCollateralFactor_whileFallbackActive_accepted_whileExpired_refused() external {
        assertEq(_cf(address(bp)), 0, "listed at CF 0");
        vault.setConvertReverts(true);
        uint256 tIn = t0 + WINDOW; // last valid second
        _at(tIn, 20e8);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "fallback active (price non-zero): accepted");
        assertEq(_cf(address(bp)), CF_SHARE);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0), 0);

        uint256 tOut = t0 + WINDOW + 1;
        _at(tOut, 20e8);
        assertEq(_price(PToken(address(bp))), 0);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "fallback expired (price 0): refused");
        assertEq(_cf(address(bp)), 0);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0), 0, "lowering to 0 is always possible");

        // a successful poke after recovery re-opens the raise
        vault.setConvertReverts(false);
        assertTrue(wrapper.poke());
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0);
    }

    /// @dev R1 = the ONE-transaction rollback `controller._setPriceOracle(guardedOracle)` while the fallback is ACTIVE.
    ///      PRECISELY: (1) pWAVAX and pUSDC are priced identically before and after (the guarded oracle is the base of the wrapper);
    ///      (2) the share market goes from 97%-of-last-good to UNPRICED (the guarded oracle returns 0 for a pToken it does not know);
    ///      (3) therefore every account that ENTERED bp (with or without a balance) gets PRICE_ERROR in every market and cannot be
    ///      liquidated, exactly as BpRollbackTest documents for a healthy vault; accounts that never entered bp are untouched;
    ///      (4) the wrapper itself is unchanged and re-installing it restores the fallback price (while the window lasts).
    function test_rollbackR1_whileFallbackActive() external {
        _raiseCf();
        _contagionDebtor(DAVE); // zero-balance entrant
        _plainDebtor(EVE); // never entered
        _openBorrow(ALICE, 100e6, 30e6); // share borrower
        vault.setConvertReverts(true);
        uint256 ts = t0 + 12 hours;
        _at(ts, 1e8); // AVAX $1: DAVE and EVE underwater
        uint256 wavax0 = _price(PToken(address(pWavax)));
        uint256 usdc0 = _price(PToken(address(pUsdc)));
        assertEq(_price(PToken(address(bp))), 0.97e30, "fallback active");

        assertEq(controller._setPriceOracle(PriceOracle(address(old))), 0, "R1: one transaction");
        assertEq(address(controller.oracle()), address(old));
        assertEq(_price(PToken(address(pWavax))), wavax0, "pWAVAX priced identically");
        assertEq(_price(PToken(address(pUsdc))), usdc0, "pUSDC priced identically");
        assertEq(_price(PToken(address(bp))), 0, "the share market becomes UNPRICED (guarded oracle: unknown pToken -> 0)");
        assertEq(wrapper.getShareUsdPrice(), 0.97e18, "the wrapper itself is unchanged: only the controller stopped reading it");

        (uint256 err,,) = controller.getAccountLiquidity(DAVE);
        assertEq(err, ERR_PRICE, "zero-balance entrant now frozen");
        _assertFrozenLiquidation(DAVE, "R1 zero-balance entrant");
        (err,,) = controller.getAccountLiquidity(ALICE);
        assertEq(err, ERR_PRICE, "share borrower frozen");
        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 1e6);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE);
        (err,,) = controller.getAccountLiquidity(EVE);
        assertEq(err, 0, "never entered bp: untouched");
        _liquidateAndCheck(EVE, 2e6);

        // roll forward again inside the window
        assertEq(controller._setPriceOracle(PriceOracle(address(wrapper))), 0);
        assertEq(_price(PToken(address(bp))), 0.97e30);
        _liquidateAndCheck(DAVE, 2e6);
    }

    // ================================================================ 6. poke poisoning, bounded at stack level
    /// @dev A feed glitch inflates the vault leg 2x. Poked right away (same timestamp as the last store) the poke is REFUSED; after the
    ///      1 h minimum interval it stores at most +2%. A borrower during the following outage is valued at 0.97 x STORED x $1.
    function test_pokePoisoning_glitch2x_pokedRightAway_isRefused() external {
        vault.setAssetsPerWholeShare(2e6); // glitch: live leg 2.0
        assertFalse(wrapper.poke(), "up-move inside POKE_UP_INTERVAL of the last store: refused");
        assertEq(wrapper.lastGoodAssetsPerShare(), 1e6, "stored value untouched");
        assertEq(wrapper.lastGoodTime(), t0);
    }

    function test_pokePoisoning_glitch2x_storedRisesByAtMost2Percent_andBorrowIsBounded() external {
        _raiseCf();
        _supplyShares(ALICE, 100e6);
        _enter(ALICE, address(bp));
        vault.setAssetsPerWholeShare(2e6);
        uint256 ts = t0 + 1 hours;
        _at(ts, 20e8);
        // while the glitch is LIVE the controller prices the share at the live 2.0 (pre-existing oracle trust in the vault, nothing to do
        // with poke or with the fallback)
        assertEq(_price(PToken(address(bp))), 2e30);
        assertTrue(wrapper.poke());
        assertEq(wrapper.lastGoodAssetsPerShare(), 1.02e6, "+2% cap, not 2x");
        assertEq(wrapper.lastGoodTime(), ts);

        // the glitch turns into an outage: the borrower is limited by 0.97 x stored x $1
        vault.setConvertReverts(true);
        uint256 tOut = ts + 1 hours;
        _at(tOut, 20e8);
        assertEq(_price(PToken(address(bp))), 0.9894e30, "0.97 x 1.02 x $1");
        (, uint256 liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(liquidity, 49.47e18, "100 shares x 0.9894 x 50%");
        assertLe(liquidity, (100e18 * 97 * 102 * 50) / (100 * 100 * 100), "never above 0.97 x stored x 1.0 x CF x shares");
        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 49.47e6 + 1);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY);
        (ok,) = _borrowUsdc(ALICE, 49.47e6);
        assertTrue(ok);
    }

    function test_pokePoisoning_sameTransactionDoublePoke_cannotCompound() external {
        vault.setAssetsPerWholeShare(2e6);
        uint256 ts = t0 + 1 hours;
        _at(ts, 20e8);
        BpPokeProbe probe = new BpPokeProbe();
        bool[] memory r = probe.pokeMany(wrapper, 8);
        assertTrue(r[0], "first poke stores");
        for (uint256 i = 1; i < r.length; i++) {
            assertFalse(r[i], "every further poke in the same transaction is refused");
        }
        assertEq(wrapper.lastGoodAssetsPerShare(), 1.02e6, "exactly one +2% step");
    }

    /// @dev Over time the bound is +2% per accepted poke and at most one up-poke per hour (header of the wrapper); three hourly pokes
    ///      give 1.02^3 (floor division at each step), never more.
    function test_pokePoisoning_hourlyPokesCompoundAtMostTwoPercentPerHour() external {
        vault.setAssetsPerWholeShare(5e6);
        uint256 stored = 1e6;
        for (uint256 h = 1; h <= 3; h++) {
            uint256 ts = t0 + h * 1 hours;
            _at(ts, 20e8);
            assertTrue(wrapper.poke());
            stored = (stored * 10_200) / 10_000;
            assertEq(wrapper.lastGoodAssetsPerShare(), stored);
            assertFalse(wrapper.poke(), "second poke at the same second refused");
        }
        assertEq(stored, 1_061_208, "1.02^3 with floor division");
    }

    function test_pokeDownIsStoredAtOnce_andLowersTheFallbackPrice() external {
        vault.setAssetsPerWholeShare(0.6e6);
        assertTrue(wrapper.poke(), "a lower value is stored immediately");
        assertEq(wrapper.lastGoodAssetsPerShare(), 0.6e6);
        vault.setConvertReverts(true);
        assertEq(_price(PToken(address(bp))), 0.582e30, "0.97 x 0.6");
    }

    /// @dev After a window of silence the next poke stores the live value whatever it is. No extra exposure: the controller already prices
    ///      the share at that same live value (the vault answers), poke only records it.
    function test_pokeAfterExpiry_storesLiveValue_priceUnchangedByThePoke() external {
        vault.setAssetsPerWholeShare(2e6);
        uint256 ts = t0 + WINDOW + 1;
        _at(ts, 20e8);
        uint256 before = _price(PToken(address(bp)));
        assertEq(before, 2e30, "live price");
        assertTrue(wrapper.poke());
        assertEq(wrapper.lastGoodAssetsPerShare(), 2e6);
        assertEq(_price(PToken(address(bp))), before, "the poke changed no controller price");
    }

    /// @dev Fuzz: whatever the live leg and however many pokes in one transaction after one hour, the stored value is at most +2% of the
    ///      previous one (or exactly the live value when it is lower).
    function testFuzz_poke_neverRaisesStoredByMoreThanTwoPercent(uint256 ppsRaw, uint8 nRaw) external {
        uint256 pps = bound(ppsRaw, 1, 1e12);
        uint256 n = bound(uint256(nRaw), 1, 12);
        vault.setAssetsPerWholeShare(pps);
        uint256 ts = t0 + 1 hours;
        _at(ts, 20e8);
        BpPokeProbe probe = new BpPokeProbe();
        probe.pokeMany(wrapper, n);
        uint256 stored = wrapper.lastGoodAssetsPerShare();
        if (pps <= 1e6) {
            assertEq(stored, pps, "lower or equal: stored as is");
        } else {
            assertLe(stored, (1e6 * 10_200) / 10_000, "never more than +2%");
            assertEq(stored, pps < 1_020_000 ? pps : 1_020_000);
        }
    }
}
