// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {TokenErrorReporter} from "../../contracts/ErrorReporter.sol";
import {BpBase} from "./BpBase.sol";

/// @notice Test 5: rollback = `controller._setPriceOracle(oldOracle)` in ONE transaction.
///
///         RESULT (what the tests below prove):
///         A) With NOBODY holding or having entered the share market, the rollback is complete and harmless: the old oracle
///            prices every existing market identically; the share market is simply priced 0 again (supply / redeem of
///            un-entered suppliers still work).
///         B) The old oracle returns 0 (it does NOT revert) for the unknown pToken, and the controller treats price 0 as
///            PRICE_ERROR for EVERY liquidity computation that includes an account that ENTERED the share market, WITH OR
///            WITHOUT a balance (entering is free, needs no balance and cannot be blocked while the market is listed).
///            Every such account is FROZEN in EVERY market (not only the share market) and is NOT LIQUIDATABLE: no new
///            borrow, no redeem (incl. pWAVAX), no exitMarket, no pToken transfer, no liquidation of it. Still working:
///            repayBorrow (own and `repayBorrowBehalf`), mint, and everything for accounts that never entered the share
///            market (including liquidation of their pWAVAX-collateral debt). Re-installing the wrapper unfreezes everyone
///            in one tx.
///         CONSEQUENCE (not a precondition): "no account has entered" cannot be ENFORCED, because any account can enter bp
///            in the block before the rollback tx lands. After a rollback, assume every debtor who chose to enter bp is
///            unliquidatable until a pricing oracle is back. The rollback is therefore a break-glass action whose cost is
///            "entered accounts frozen and unliquidatable", to be compared with the cost of leaving a faulty wrapper in place;
///            check `MarketEntered` events for bp beforehand to know who would be affected.
contract BpRollbackTest is BpBase {
    address internal constant DAVE = address(0xDA7E);
    address internal constant EVE = address(0xE5E);
    address internal constant FRANK = address(0xF7A);

    function setUp() public override {
        super.setUp();
        _listShareMarket();
        require(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE) == 0);
    }

    function _rollback() internal {
        assertEq(controller._setPriceOracle(PriceOracle(address(old))), 0, "one tx, success");
        assertEq(address(controller.oracle()), address(old));
    }

    function _rollForward() internal {
        assertEq(controller._setPriceOracle(PriceOracle(address(wrapper))), 0);
        assertEq(address(controller.oracle()), address(wrapper));
    }

    function _populate() internal {
        _openBorrow(ALICE, 100e6, 40e6); // entered bp, debt
        _supplyShares(BOB, 50e6);
        _enter(BOB, address(bp)); // entered bp, no debt
        _supplyShares(CAROL, 10e6); // supplier, never entered
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6); // pWAVAX-only borrower
        assertTrue(ok);
        _mintUnderlyingP(pWavax, EVE, 10e18);
        _enter(EVE, address(pWavax));
        _openBorrow(EVE, 100e6, 20e6); // both markets entered, debt
    }

    // =================================================================== A) rollback before anyone entered
    function test_rollbackBeforeAnyAccountEntered_isCompleteAndHarmless() external {
        uint256 pTokens = _supplyShares(CAROL, 10e6); // supplied, not entered
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6);
        assertTrue(ok);

        uint256 wavaxPrice = _price(PToken(address(pWavax)));
        uint256 usdcPrice = _price(PToken(address(pUsdc)));
        _rollback();
        assertEq(_price(PToken(address(pWavax))), wavaxPrice, "existing markets: same price");
        assertEq(_price(PToken(address(pUsdc))), usdcPrice);
        assertEq(_price(PToken(address(bp))), 0, "share market unpriced (old oracle: 0, no revert)");

        // everything for existing accounts works
        (ok,) = _borrowUsdc(DAVE, 5e6);
        assertTrue(ok, "pWAVAX-collateral borrower still borrows");
        (ok,) = _repayUsdc(DAVE, 15e6);
        assertTrue(ok);
        // un-entered share supplier: redeem and supply still work
        (ok,) = _redeemShares(CAROL, pTokens);
        assertTrue(ok, "un-entered supplier redeems");
        _supplyShares(CAROL, 1e6);
        // nobody can borrow against the share market any more: CF raise refused
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE);
        // and the share market itself is still not borrowable
        assertTrue(controller.borrowGuardianPaused(address(bp)));
        _rollForward();
        assertGt(_price(PToken(address(bp))), 0, "roll forward restores the price in one tx");
    }

    function test_rollbackBeforeEntry_butSomeoneEntersAfterwards_freezesOnlyThemselves() external {
        _rollback();
        _supplyShares(BOB, 10e6);
        _enter(BOB, address(bp)); // allowed: the market is still listed
        (uint256 err,,) = controller.getAccountLiquidity(BOB);
        assertEq(err, ERR_PRICE, "BOB's liquidity is unavailable");
        (bool ok, bytes memory ret) = _redeemShares(BOB, 1);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE);
        // an unrelated account is untouched
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (ok,) = _borrowUsdc(DAVE, 5e6);
        assertTrue(ok);
    }

    // =================================================================== B) rollback after entry + borrow
    function test_rollbackAfterEntryAndBorrow_oldOracleReturnsZero_notRevert() external {
        _populate();
        _rollback();
        assertEq(old.getUnderlyingPrice(PToken(address(bp))), 0, "returns 0");
        (bool ok,) = address(old).staticcall(abi.encodeCall(PriceOracle.getUnderlyingPrice, (PToken(address(bp)))));
        assertTrue(ok, "does not revert, so unrelated controller views keep working");
        (uint256 err,,) = controller.getAccountLiquidity(ALICE);
        assertEq(err, ERR_PRICE, "entered account: PRICE_ERROR");
        (err,,) = controller.getAccountLiquidity(DAVE);
        assertEq(err, 0, "pWAVAX-only account: fine");
        (err,,) = controller.getAccountLiquidity(CAROL);
        assertEq(err, 0, "un-entered supplier: fine");
    }

    function test_rollbackAfterEntryAndBorrow_whatFreezes() external {
        _populate();
        uint256 aliceTokens = bp.balanceOf(ALICE);
        _rollback();
        bool ok;
        bytes memory ret;

        // --- ALICE (entered bp, debt 40): frozen
        (ok, ret) = _borrowUsdc(ALICE, 1e6);
        assertFalse(ok, "new borrow");
        assertEq(_errCode(ret), ERR_PRICE);
        (ok, ret) = _redeemShares(ALICE, aliceTokens / 100);
        assertFalse(ok, "redeem shares");
        assertEq(_errCode(ret), ERR_PRICE);
        vm.prank(ALICE);
        (ok,) = address(bp).call(abi.encodeWithSignature("transfer(address,uint256)", BOB, aliceTokens / 100));
        assertFalse(ok, "pToken transfer");
        vm.prank(ALICE);
        uint256 exitCode = controller.exitMarket(address(bp));
        assertTrue(exitCode != 0, "exitMarket refused (nonzero debt, and price 0)");
        (ok,) = _liquidate(FRANK, ALICE, 1e6);
        assertFalse(ok, "LIQUIDATION of the entered borrower is impossible while the old oracle is installed");
        assertEq(_errCode(lastRevert), ERR_PRICE);

        // --- ALICE can still REPAY (partial and full), mint more shares
        (ok,) = _repayUsdc(ALICE, 10e6);
        assertTrue(ok, "partial repay works");
        _supplyShares(ALICE, 1e6); // mint works
        // third-party repay on behalf of ALICE works too
        usdc.mint(FRANK, 5e6);
        vm.startPrank(FRANK);
        usdc.approve(address(pUsdc), 5e6);
        assertEq(pUsdc.repayBorrowBehalf(ALICE, 5e6), 0, "repayBorrowBehalf works");
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(ALICE), 25e6);
        (ok,) = _repayUsdc(ALICE, type(uint256).max);
        assertTrue(ok, "full repay works");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 0);

        // --- even with ZERO debt, ALICE (and BOB) stay frozen: the price-0 asset is still in their asset list
        (ok, ret) = _redeemShares(ALICE, 1);
        assertFalse(ok, "debt-free but entered: redeem still blocked");
        assertEq(_errCode(ret), ERR_PRICE);
        vm.prank(ALICE);
        exitCode = controller.exitMarket(address(bp));
        assertTrue(exitCode != 0, "debt-free exitMarket still refused (needs a price)");
        (ok, ret) = _redeemShares(BOB, 1);
        assertFalse(ok, "BOB entered, never borrowed: redeem blocked");
        assertEq(_errCode(ret), ERR_PRICE);

        // --- EVE entered BOTH markets: her pWAVAX redeem and USDC borrow are frozen too
        (ok, ret) = _try(EVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e8));
        assertFalse(ok, "pWAVAX redeem of an account that also entered bp");
        assertEq(_errCode(ret), ERR_PRICE);
        (ok,) = _borrowUsdc(EVE, 1e6);
        assertFalse(ok);

        // --- UNAFFECTED: DAVE (pWAVAX only), CAROL (never entered)
        (ok,) = _borrowUsdc(DAVE, 1e6);
        assertTrue(ok, "DAVE still borrows");
        (ok,) = _try(DAVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1e7));
        assertTrue(ok, "DAVE still redeems pWAVAX");
        (ok,) = _redeemShares(CAROL, bp.balanceOf(CAROL));
        assertTrue(ok, "CAROL (never entered) redeems the shares");
        _supplyShares(CAROL, 5e6); // and mints
        // liquidation of a pWAVAX-collateral account still works
        avaxFeed.setRound(1e8, block.timestamp, 9, 9); // AVAX $1: DAVE underwater
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertTrue(ok, "pWAVAX-collateral liquidation unaffected by the rollback");
        avaxFeed.setRound(20e8, block.timestamp, 10, 10);

        // --- roll forward unfreezes everything in one tx
        _rollForward();
        (ok,) = _redeemShares(ALICE, 1e3);
        assertTrue(ok, "ALICE redeems again");
        (ok,) = _borrowUsdc(BOB, 1e6);
        assertTrue(ok, "BOB borrows again");
        vm.prank(ALICE);
        assertEq(controller.exitMarket(address(bp)), 0, "ALICE (debt-free) can exit the share market now");
    }

    function test_rollbackAfterEntry_liquidationOfShareBorrowerIsImpossible_badDebtRisk() external {
        _populate();
        vault.setAssetsPerWholeShare(0.6e6); // ALICE (and EVE) now liquidatable at a fresh price
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertGt(shortfall, 0);
        _rollback();
        (bool ok,) = _liquidate(FRANK, ALICE, 10e6);
        assertFalse(ok, "after the rollback an underwater share borrower cannot be liquidated");
        assertEq(_errCode(lastRevert), ERR_PRICE);
        _rollForward();
        (ok,) = _liquidate(FRANK, ALICE, 10e6);
        assertTrue(ok, "liquidatable again after roll forward");
    }

    /// @dev The entry costs nothing: an account that holds NO bp enters it one block before the rollback and is then frozen
    ///      and unliquidatable. Also shows the same account is liquidatable before the rollback.
    function test_rollback_zeroBalanceEntrantBecomesUnliquidatable() external {
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6);
        assertTrue(ok);
        _enter(DAVE, address(bp)); // zero bp balance, free
        _mintUnderlyingP(pWavax, EVE, 10e18);
        _enter(EVE, address(pWavax));
        (ok,) = _borrowUsdc(EVE, 10e6);
        assertTrue(ok);
        avaxFeed.setRound(1e8, block.timestamp, 9, 9); // DAVE underwater
        (, , uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(shortfall, 0);
        uint256 snap = vm.snapshotState();
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertTrue(ok, "liquidatable with the wrapper installed");
        vm.revertToState(snap);
        _rollback();
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertFalse(ok, "after the rollback a zero-balance entrant of bp is unliquidatable");
        assertEq(_errCode(lastRevert), ERR_PRICE);
        // an identical debtor who did NOT enter bp stays liquidatable
        (ok,) = _liquidateSeizing(FRANK, EVE, 2e6, address(pWavax));
        assertTrue(ok, "debtor that never entered bp is unaffected");
    }

    function test_rollbackAfterEntry_cfZeroDoesNotHelp_priceStillRequired() external {
        _populate();
        require(controller._setCollateralFactor(PToken(address(bp)), 0) == 0);
        _rollback();
        (bool ok, bytes memory ret) = _redeemShares(BOB, 1);
        assertFalse(ok, "CF 0 does not remove the account's dependency on a price for the share market");
        assertEq(_errCode(ret), ERR_PRICE);
    }

    function test_rollbackAfterEntry_emergencyPriceOnSourceOracleDoesNotHelp() external {
        // The old guarded oracle ignores the source's owner-set emergency prices, and the source has no market
        // registration for the share pToken, so there is no oracle-side workaround while the old oracle is installed.
        _populate();
        _rollback();
        inner.registerMarket(address(bp), address(vault)); // owner can register the share market in the SOURCE ...
        inner.setEmergencyPrice(address(vault), 1e18, uint64(block.timestamp + 30 minutes)); // ... and set an emergency price
        assertEq(_price(PToken(address(bp))), 0, "guarded oracle never reads emergency prices and has no feed for the vault");
        (bool ok,) = _redeemShares(BOB, 1);
        assertFalse(ok);
    }
}
