// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "@peridot/margin/IsolatedMarginTypes.sol";
import {RangeFixture, INfpView} from "./RangeFixture.sol";
import {RangeTakeProfit} from "../src/RangeTakeProfit.sol";

/// @notice Lifecycle of the range take-profit on the live Pharaoh WAVAX/USDC pool (fork, pinned block). One test = one fork state:
/// create, partial fill, reversal, owner cancel, finalisation by a keeper, fee split, with each preset and the 70/20/10 ladder.
contract RangeLifecycleForkTest is RangeFixture {
    uint256 internal constant MARGIN = 90e6; // 90 USDC of margin at 2x: a position of about USD 180, under the USD 200 pilot cap

    // ----------------------------------------------------------------- helpers
    function _create(uint256 id, uint8 preset) internal returns (RangeTakeProfit.Order memory o) {
        uint256 gas0 = gasleft();
        vm.prank(ALICE);
        rtp.createRangeOrder(id, preset, 0);
        emit log_named_uint(preset == 4 ? "gas createRangeOrder (3 rungs)" : "gas createRangeOrder (1 rung)", gas0 - gasleft());
        o = rtp.getOrder(id);
    }

    function _ownerEquityUsdc(address owner) internal view returns (uint256) {
        return Math.mulDiv(mVault.freeBalance(owner, PUSDC), pUsdc.exchangeRateStored(), 1e18);
    }

    /// custodian holds no WAVAX, no USDC and no rewards after an order ends
    function _custodianEmpty() internal view {
        assertEq(IERC20(WAVAX).balanceOf(address(rtp)), 0, "custodian WAVAX");
        assertEq(IERC20(USDC).balanceOf(address(rtp)), 0, "custodian USDC");
    }

    // ----------------------------------------------------------------- table and placement
    function test_00_presetTable() public view {
        RangeTakeProfit.Preset memory p1 = rtp.getPreset(1);
        RangeTakeProfit.Preset memory p2 = rtp.getPreset(2);
        RangeTakeProfit.Preset memory p3 = rtp.getPreset(3);
        RangeTakeProfit.Preset memory p4 = rtp.getPreset(4);
        assertTrue(p1.enabled && p2.enabled && p3.enabled && p4.enabled);
        assertEq(p1.distanceTicks[0], 100);
        assertEq(p2.distanceTicks[0], 300);
        assertEq(p3.distanceTicks[0], 490);
        assertEq(p1.widthTicks[0], 200);
        assertEq(p4.levels, 3);
        assertEq(p4.weightBps[0], 7_000);
        assertEq(p4.weightBps[1], 2_000);
        assertEq(p4.weightBps[2], 1_000);
        assertEq(p4.distanceTicks[2], 490);
        assertEq(rtp.tickSpacing(), 10);
        assertFalse(rtp.getPreset(5).enabled);
    }

    function _checkSingle(uint8 preset, int24 distance) internal {
        uint256 id = _open(ALICE, MARGIN);
        uint256 healthBefore = _health(id);
        uint256 collBefore = _collateral(id);
        (, int24 tick) = _slot0();
        RangeTakeProfit.Order memory o = _create(id, preset);
        assertEq(uint8(o.status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(o.rungCount, 1);
        RangeTakeProfit.Rung memory r = o.rungs[0];
        // the band sits entirely above the tick, aligned to the spacing, the near edge never closer than the preset distance
        assertGe(r.tickLower, tick + distance, "near edge not closer than the preset");
        assertLt(r.tickLower, tick + distance + 10, "snapped up by less than one spacing");
        assertEq(r.tickLower % 10, 0);
        assertEq(r.tickUpper - r.tickLower, 200);
        assertEq(INfpView(PHARAOH_NFPM).ownerOf(r.tokenId), address(rtp), "the custodian holds the NFT");
        assertGt(r.liquidity, 0);
        assertApproxEqAbs(r.collateralCommitted, collBefore, collBefore / 1_000_000 + 2, "all collateral committed");
        // collateral left the account; the risk engine counts the band at the oracle: health unchanged
        assertLe(_collateral(id), 2, "nothing left in the account");
        uint256 healthAfter = _health(id);
        assertApproxEqAbs(healthAfter, healthBefore, 2, "health unchanged by committing the band");
        (uint256 hc, uint256 hq) = rtp.holdings(_pos(id).account);
        assertApproxEqAbs(hc, r.collateralCommitted, r.collateralCommitted / 1_000_000 + 2, "band valued as all WAVAX below the band");
        assertEq(hq, 0);
        assertEq(rtp.positionOfAccount(_pos(id).account), id);
        assertEq(rtp.activeOrders(), 1);
        emit log_named_int("pool tick", tick);
        emit log_named_int("band lower", r.tickLower);
        emit log_named_int("band upper", r.tickUpper);
        emit log_named_uint("WAVAX committed (1e18)", r.collateralCommitted);
        emit log_named_uint("health bps before / after", healthBefore * 1e6 + healthAfter);
    }

    function test_01a_create_preset1() public {
        _checkSingle(1, 100);
    }

    function test_01b_create_preset2() public {
        _checkSingle(2, 300);
    }

    function test_01c_create_preset3() public {
        _checkSingle(3, 490);
    }

    /// Placement from a tick that is NOT on the spacing (and a negative one): the near edge is snapped AWAY from the market, never closer than
    /// the preset's distance (the pool tick at the pin happens to be a multiple of 10, so move it first).
    function test_01d_create_fromAnOffSpacingTick() public {
        uint256 id = _open(ALICE, MARGIN);
        (, int24 tick0) = _slot0();
        _market(tick0 + 7); // tick -254513: 7 above a multiple of 10
        (, int24 tick) = _slot0();
        assertEq(tick % 10, -3, "off the spacing");
        RangeTakeProfit.Order memory o = _create(id, 1);
        assertGe(o.rungs[0].tickLower, tick + 100, "not closer than 100 ticks");
        assertEq(o.rungs[0].tickLower % 10, 0);
        assertLt(o.rungs[0].tickLower, tick + 100 + 10);
        assertEq(o.rungs[0].tickLower, -254_410);
    }

    function test_02_create_ladder_70_20_10() public {
        uint256 id = _open(ALICE, MARGIN);
        (, int24 tick) = _slot0();
        RangeTakeProfit.Order memory o = _create(id, 4);
        assertEq(o.rungCount, 3);
        uint256 total;
        int24[3] memory dist = [int24(100), 300, 490];
        for (uint256 i; i < 3; ++i) {
            RangeTakeProfit.Rung memory r = o.rungs[i];
            total += r.collateralCommitted;
            assertGe(r.tickLower, tick + dist[i]);
            assertLt(r.tickLower, tick + dist[i] + 10);
            assertEq(r.tickUpper - r.tickLower, 200);
            assertGt(r.liquidity, 0);
            assertEq(INfpView(PHARAOH_NFPM).ownerOf(r.tokenId), address(rtp));
        }
        // 70 / 20 / 10 of what was committed (the last rung takes the rounding remainder)
        assertEq(o.rungs[0].collateralCommitted, Math.mulDiv(total, 7_000, 10_000));
        assertApproxEqAbs(o.rungs[1].collateralCommitted, Math.mulDiv(total, 2_000, 10_000), 1);
        assertApproxEqAbs(o.rungs[2].collateralCommitted, Math.mulDiv(total, 1_000, 10_000), 2);
        assertEq(o.rungs[0].collateralCommitted + o.rungs[1].collateralCommitted + o.rungs[2].collateralCommitted, total);
        // rungs rise. As ported (100/300/490 ticks, 200 wide): rung 1 and 2 TOUCH (200 -> 300 edge), rung 2 and 3 OVERLAP by one spacing
        assertEq(o.rungs[0].tickUpper, o.rungs[1].tickLower, "rungs 1 and 2 touch");
        assertLt(o.rungs[1].tickLower, o.rungs[2].tickLower);
        assertEq(o.rungs[1].tickUpper - o.rungs[2].tickLower, 10, "rungs 2 and 3 overlap by one spacing");
        assertLe(_collateral(id), 2);
        (uint256 hc,) = rtp.holdings(_pos(id).account);
        assertApproxEqAbs(hc, total, total / 1_000_000 + 4);
    }

    // ----------------------------------------------------------------- full lifecycle, each preset
    function _lifecycle(uint8 preset) internal {
        uint256 id = _open(ALICE, MARGIN);
        uint256 debt0 = _debt(id);
        RangeTakeProfit.Order memory o = _create(id, preset);
        int24 upper = o.rungs[0].tickUpper;
        // not reached: the keeper's call refuses
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id);
        (uint8 act, uint8 ready) = rtp.finalizable(id);
        assertEq(act, 1);
        assertEq(ready, 0);

        _market(upper + 5); // the market trades up through the band; the oracle follows
        (act, ready) = rtp.finalizable(id);
        assertEq(ready, 1, "rung fully crossed");
        (uint256 hc, uint256 hq) = rtp.holdings(_pos(id).account);
        assertGt(hq, 0, "valued as USDC at the oracle");
        assertLt(hc, 1e12, "no WAVAX left in the band");

        uint256 gas0 = gasleft();
        vm.prank(KEEPER);
        rtp.finalize(id);
        emit log_named_uint("gas finalize (1 rung)", gas0 - gasleft());

        IsolatedMarginTypes.Position memory p = _pos(id);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.CLOSED), "position closed");
        assertEq(pUsdc.borrowBalanceCurrent(p.account), 0, "debt repaid");
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.SETTLED));
        assertEq(rtp.activeOrders(), 0);
        assertEq(rtp.positionOfAccount(p.account), 0);
        _custodianEmpty();
        // the owner got the remainder: margin 90 + the 2x gain through the band, minus interest/fees
        uint256 equity = _ownerEquityUsdc(ALICE);
        emit log_named_uint("owner equity USDC (1e6) from margin 90", equity);
        emit log_named_uint("debt repaid (1e6)", debt0);
        assertGt(equity, MARGIN + 1e6, "2x gain through a band above the market");
    }

    function test_03a_lifecycle_preset1() public {
        _lifecycle(1);
    }

    function test_03b_lifecycle_preset2() public {
        _lifecycle(2);
    }

    function test_03c_lifecycle_preset3() public {
        _lifecycle(3);
    }

    /// The ladder crossed in stages: rung 1 (70 %) repays the debt FIRST and the position stays open (debt-free) on the other 30 %;
    /// the last rung's finalisation returns the equity to the owner and closes the position.
    function test_04_ladder_staged() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 4);
        address acct = _pos(id).account;

        _market(o.rungs[0].tickUpper + 5);
        (uint8 act, uint8 ready) = rtp.finalizable(id);
        assertEq(act, 3);
        assertEq(ready, 1);
        uint256 gas0 = gasleft();
        vm.prank(KEEPER);
        rtp.finalize(id);
        emit log_named_uint("gas finalize (rung 1 of 3, position stays open)", gas0 - gasleft());
        assertEq(pUsdc.borrowBalanceCurrent(acct), 0, "debt repaid FIRST, from rung 1");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE), "still open: rungs 2 and 3 are active");
        o = rtp.getOrder(id);
        assertEq(uint8(o.status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(uint8(o.rungs[0].status), uint8(RangeTakeProfit.Status.SETTLED));
        assertEq(uint8(o.rungs[1].status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(_ownerEquityUsdc(ALICE), 0, "nothing paid out until the last rung");
        assertFalse(riskEngine.isLiquidatable(acct));
        // rung 1 again: nothing ready, refuses
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id);

        _market(o.rungs[1].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE), "rung 3 still active");
        _market(o.rungs[2].tickUpper + 5);
        gas0 = gasleft();
        vm.prank(KEEPER);
        rtp.finalize(id);
        emit log_named_uint("gas finalize (last rung, closes the position)", gas0 - gasleft());
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.SETTLED));
        assertEq(rtp.activeOrders(), 0);
        _custodianEmpty();
        uint256 equity = _ownerEquityUsdc(ALICE);
        emit log_named_uint("owner equity USDC (1e6) after the ladder", equity);
        assertGt(equity, MARGIN + 2e6);
    }

    /// The ladder crossed in one move: a single finalisation takes all three rungs.
    function test_05_ladder_oneMove() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 4);
        _market(o.rungs[2].tickUpper + 5);
        (uint8 act, uint8 ready) = rtp.finalizable(id);
        assertEq(act, 3);
        assertEq(ready, 3);
        uint256 gas0 = gasleft();
        vm.prank(KEEPER);
        rtp.finalize(id);
        emit log_named_uint("gas finalize (3 rungs at once)", gas0 - gasleft());
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pUsdc.borrowBalanceCurrent(_pos(id).account), 0);
        _custodianEmpty();
        assertGt(_ownerEquityUsdc(ALICE), MARGIN + 3e6);
    }

    // ----------------------------------------------------------------- partial fill, reversal, price back inside
    function test_06_partialFill_thenReversal() public {
        uint256 id = _open(ALICE, MARGIN);
        uint256 coll0 = _collateral(id);
        RangeTakeProfit.Order memory o = _create(id, 1);
        int24 lower = o.rungs[0].tickLower;
        address acct = _pos(id).account;
        int24 tick0;
        (, tick0) = _slot0();

        _market(lower + 100); // mid-band
        (uint256 hc, uint256 hq) = rtp.holdings(acct);
        assertGt(hc, 0, "still holds WAVAX");
        assertGt(hq, 0, "and USDC");
        emit log_named_uint("mid-band WAVAX (1e18)", hc);
        emit log_named_uint("mid-band USDC (1e6)", hq);
        (, uint8 ready) = rtp.finalizable(id);
        assertEq(ready, 0);
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id);
        assertGt(_debt(id), 0, "a partial fill repays nothing");
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE));

        _market(tick0); // the price reverses to where it began
        (hc, hq) = rtp.holdings(acct);
        assertApproxEqAbs(hc, o.rungs[0].collateralCommitted, o.rungs[0].collateralCommitted / 100, "the WAVAX is back (to rounding)");
        assertLe(hq, 10, "no USDC left (dust)");
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id);

        // the owner can still cancel and gets all the WAVAX back as collateral
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        assertApproxEqRel(_collateral(id), coll0, 2e15, "collateral restored after the reversal (fees add a little)");
        assertGt(_collateral(id) + 1, coll0 - coll0 / 500);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
    }

    /// The band is crossed, and then the price falls back INTO the band before the keeper finalises: not final; refused.
    function test_07_priceReturnsInsideRange_afterCrossing() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        (, uint8 ready) = rtp.finalizable(id);
        assertEq(ready, 1);
        _market(o.rungs[0].tickUpper - 60); // back inside the band, near its top
        (, ready) = rtp.finalizable(id);
        assertEq(ready, 0);
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id);
        // and it converts again when the market goes back up
        _market(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    // ----------------------------------------------------------------- partial commitment
    function test_08_partialCommit_halfTheCollateral() public {
        uint256 id = _open(ALICE, MARGIN);
        uint256 half = pWavax.balanceOf(_pos(id).account) / 2;
        vm.prank(ALICE);
        rtp.createRangeOrder(id, 1, half);
        RangeTakeProfit.Order memory o = rtp.getOrder(id);
        assertApproxEqRel(o.rungs[0].collateralCommitted, _collateral(id), 1e12, "half committed, half left in the account");
        _market(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        // the band's USDC repays what it can; the position closes if the proceeds covered the debt, else stays open debt-reduced
        emit log_named_uint("status after the half-commit finalisation (2 = ACTIVE, 5 = CLOSED)", uint256(_pos(id).status));
        // the order itself is over; the uncommitted half is still a normal margin position, and the debt only went down
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.SETTLED));
        _custodianEmpty();
    }

    // ----------------------------------------------------------------- owner cancel
    function test_09_ownerCancel_restoresEverything_andANewOrderIsPossible() public {
        uint256 id = _open(ALICE, MARGIN);
        uint256 coll0 = _collateral(id);
        uint256 debt0 = _debt(id);
        RangeTakeProfit.Order memory o = _create(id, 4);
        // a stranger cannot cancel
        vm.prank(STRANGER);
        vm.expectRevert(RangeTakeProfit.NotAuthorized.selector);
        rtp.unwind(id);
        uint256 gas0 = gasleft();
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        emit log_named_uint("gas unwind (3 rungs)", gas0 - gasleft());
        assertApproxEqAbs(_collateral(id), coll0, coll0 / 1_000_000 + 4, "all collateral back");
        assertApproxEqAbs(_debt(id), debt0, debt0 / 1_000_000 + 2, "debt untouched");
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.UNWOUND));
        assertEq(uint8(rtp.getOrder(id).rungs[1].status), uint8(RangeTakeProfit.Status.UNWOUND));
        assertEq(rtp.activeOrders(), 0);
        _custodianEmpty();
        (bool exists,) = PHARAOH_NFPM.staticcall(abi.encodeWithSelector(INfpView.ownerOf.selector, o.rungs[0].tokenId));
        assertFalse(exists, "NFT burned");
        // idempotent: nothing active, returns false
        vm.prank(ALICE);
        assertFalse(rtp.unwind(id));
        // a new order on the same position works
        vm.prank(ALICE);
        rtp.createRangeOrder(id, 2, 0);
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE));
    }

    function test_10_cancelAfterPartialFill_returnsStockAndUsdc() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickLower + 100);
        uint256 debt0 = _debt(id);
        vm.prank(ALICE);
        rtp.unwind(id);
        // the band's USDC went to the debt (repaid first), the WAVAX back to collateral
        assertLt(_debt(id), debt0, "USDC from the partial fill repaid debt");
        assertGt(_collateral(id), 0);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        _custodianEmpty();
    }

    // ----------------------------------------------------------------- the 70/20/10 FEE split (PR #7) on swap fees
    /// PHARAOH DIFFERENCE: at the pin the pool's protocol fee is 100 % (feeProtocol = 1e6): LPs earn NO swap fees on this pool. The
    /// custodian's fee split therefore pays nothing on the live pool; it is kept for parity with PR #7 and for the day governance moves it.
    function test_11a_livePool_paysNoSwapFeesToTheBand() public {
        assertEq(_liveFeeProtocol(), 1_000_000, "pool feeProtocol at the pin");
        vm.prank(LEDGER);
        rtp.setFeeSplit(7_000, 2_000, 1_000, PROTOCOL, RESERVE);
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(_fee(PROTOCOL), 0, "no swap fees accrue to the LP band");
        assertEq(_fee(RESERVE), 0);
    }

    /// STUB TEST (the live pool pays the band no fees, test_11a; an attempt to set the pool's feeProtocol to 0 through its storage did not
    /// make fees appear, so the swap-fee accounting of this pool is not understood well enough to fake it): the position manager's
    /// `collect` and `burn` are mocked to report `X` of fees on top of the principal, and the tokens are dealt to the custodian. This proves
    /// the split arithmetic, the snapshot and the payout of `_removeRung`, NOT that the pool ever produces such fees.
    function test_11_feeSplit_70_20_10_stubbedFees() public {
        vm.prank(LEDGER);
        rtp.setFeeSplit(7_000, 2_000, 1_000, PROTOCOL, RESERVE);
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        assertEq(o.userFeeBps, 7_000);
        assertEq(o.protocolFeeBps, 2_000);
        assertEq(o.reserveFeeBps, 1_000);
        // the split is a snapshot: a later change does not touch this order
        vm.prank(LEDGER);
        rtp.setFeeSplit(10_000, 0, 0, PROTOCOL, RESERVE); // (recipients are global in PR #7 as here; only the bps are snapshotted)
        _market(o.rungs[0].tickUpper + 5);
        uint256 x = 10_000_000; // 10 USDC of "fees"
        uint256 c1 = o.rungs[0].quoteExpected + x;
        deal(USDC, address(rtp), c1);
        deal(WAVAX, address(rtp), 1e6 + o.rungs[0].collateralIdle);
        vm.mockCall(PHARAOH_NFPM, abi.encodeWithSignature("collect((uint256,address,uint128,uint128))"), abi.encode(uint256(1e6), c1));
        vm.mockCall(PHARAOH_NFPM, abi.encodeWithSignature("burn(uint256)"), "");
        vm.prank(KEEPER);
        rtp.finalize(id);
        uint256 dp = _fee(PROTOCOL);
        uint256 dr = _fee(RESERVE);
        emit log_named_uint("protocol fee share (USDC 1e6) of 10 USDC", dp);
        emit log_named_uint("reserve fee share (USDC 1e6)", dr);
        // fees = c1 - principal (principal is quoteExpected to within rounding): 20 % and 10 % of ~10 USDC
        assertApproxEqAbs(dp, 2_000_000, 5);
        assertApproxEqAbs(dr, 1_000_000, 5);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        _custodianEmpty();
    }

    function test_11b_feeSplit_validation() public {
        vm.startPrank(LEDGER);
        vm.expectRevert(RangeTakeProfit.InvalidFeeSplit.selector);
        rtp.setFeeSplit(7_000, 2_000, 2_000, PROTOCOL, RESERVE); // not 100 %
        vm.expectRevert(RangeTakeProfit.InvalidFeeSplit.selector);
        rtp.setFeeSplit(7_000, 2_000, 1_000, address(0), RESERVE); // a share with no recipient
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(RangeTakeProfit.NotAdmin.selector);
        rtp.setFeeSplit(10_000, 0, 0, address(0), address(0));
    }

    /// A fee recipient that cannot receive USDC (a blacklisted address, modelled by a reverting transfer) must not block finalisation
    /// or an unwind: the share stays in the owner's proceeds.
    function test_11c_feeRecipientTransferFails_neverBlocksARiskPath() public {
        vm.prank(LEDGER);
        rtp.setFeeSplit(7_000, 2_000, 1_000, PROTOCOL, RESERVE);
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        // revert for ANY amount to the protocol recipient
        bytes memory anyAmount = abi.encodeWithSelector(IERC20.transfer.selector, PROTOCOL);
        vm.mockCallRevert(USDC, anyAmount, "blacklisted");
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED), "finalised despite the failing transfer");
        assertEq(_fee(PROTOCOL), 0);
    }
}
