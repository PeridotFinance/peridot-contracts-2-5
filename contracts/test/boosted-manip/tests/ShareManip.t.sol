// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {console2} from "forge-std/Test.sol";

import {ManipBase} from "./ManipBase.sol";
import {PharaohDlmmVault} from "../vault-src/PharaohDlmmVault.sol";
import {IPharaohDlmmVault} from "../vault-src/IPharaohDlmmVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

import {SimpleFlashLoanVault} from "../../../contracts/margin/SimpleFlashLoanVault.sol";
import {IERC3156FlashBorrower} from "../../../contracts/PTokenInterfaces.sol";
import {PharaohVaultShareOracle} from "../../../contracts/PharaohVaultShareOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @notice Harness of the lending side. NOT the controller: it mirrors the three checks of Peridottroller.borrowAllowed that bound an extraction
///         (collateral value = shares x the oracle price x CF, `nextTotalBorrows < borrowCap`, PeridottrollerAvalanche cash floor) and holds the shares as collateral.
///         The pToken exchange rate is abstracted to 1 share per pToken unit (the dead seed pins it); see the doc, section 2.
contract LenderHarness {
    IERC20 public immutable usdc;
    IERC20 public immutable shares;
    PharaohVaultShareOracle public immutable oracle;
    address public immutable pShare;
    uint256 public immutable cfBps;
    uint256 public immutable cap;
    uint256 public immutable floor_;
    uint256 public totalBorrows;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(IERC20 usdc_, IERC20 shares_, PharaohVaultShareOracle o, address pShare_, uint256 cf, uint256 cap_, uint256 floor__) {
        usdc = usdc_;
        shares = shares_;
        oracle = o;
        pShare = pShare_;
        cfBps = cf;
        cap = cap_;
        floor_ = floor__;
    }

    function value18(uint256 shareAmt) public view returns (uint256) {
        return shareAmt * oracle.getUnderlyingPrice(PToken(pShare)) / 1e18;
    }

    function supplyAndBorrow(uint256 shareAmt, uint256 amt) external {
        shares.transferFrom(msg.sender, address(this), shareAmt);
        collateral[msg.sender] += shareAmt;
        debt[msg.sender] += amt;
        totalBorrows += amt;
        require(amt * 1e12 <= value18(collateral[msg.sender]) * cfBps / 10_000, "insufficient liquidity");
        require(totalBorrows < cap, "market borrow cap reached");
        uint256 cash = usdc.balanceOf(address(this));
        require(cash >= amt && cash - amt >= floor_, "borrow cash floor");
        usdc.transfer(msg.sender, amt);
    }
}

/// @dev flash-funded attacker: takes the flash loan, donates, supplies its shares, borrows, repays the flash loan, all in the callback
contract FlashDonator is IERC3156FlashBorrower {
    SimpleFlashLoanVault public immutable flash;
    IERC20 public immutable usdc;
    IERC20 public immutable vaultShares;
    address public immutable vault;
    LenderHarness public immutable lender;
    uint256 public donate;
    uint256 public borrowAmt;

    constructor(SimpleFlashLoanVault f, IERC20 usdc_, address vault_, LenderHarness l) {
        flash = f;
        usdc = usdc_;
        vault = vault_;
        vaultShares = IERC20(vault_);
        lender = l;
    }

    function depositOwn(uint256 assets) external {
        usdc.approve(vault, assets);
        IERC4626(vault).deposit(assets, address(this));
    }

    function run(uint256 flashAmt, uint256 donate_, uint256 borrow_) external {
        donate = donate_;
        borrowAmt = borrow_;
        if (flashAmt == 0) {
            _body(0);
        } else {
            flash.flashLoan(this, address(usdc), flashAmt, "");
        }
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata) external returns (bytes32) {
        require(msg.sender == address(flash), "not the flash vault");
        _body(amount + fee);
        usdc.approve(address(flash), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _body(uint256) private {
        if (donate != 0) usdc.transfer(vault, donate); // DONATION: a plain ERC-20 transfer to the vault address
        uint256 s = vaultShares.balanceOf(address(this));
        if (s != 0) {
            vaultShares.approve(address(lender), s);
            lender.supplyAndBorrow(s, borrowAmt);
        }
    }
}

contract ShareManipTest is ManipBase {
    SimpleFlashLoanVault internal flash;
    LenderHarness internal lender;
    FlashDonator internal atk;

    function setUp() public {
        _setUpManip();
        // the margin stack's flash vault, REAL contract, as on chain: 100 USDC, fee 0, USDC allowed; flashLoan has no caller check
        flash = new SimpleFlashLoanVault(SAFE);
        vm.startPrank(SAFE);
        flash.setTokenAllowed(address(usdc), true);
        flash.setFeeBps(0);
        vm.stopPrank();
        usdc.mint(SAFE, 100e6);
        vm.startPrank(SAFE);
        usdc.approve(address(flash), 100e6);
        flash.depositLiquidity(address(usdc), 100e6);
        vm.stopPrank();
        // lender: pUSDC cash 274, cap 200 (strict <), floor 50, CF 50 %
        lender = new LenderHarness(IERC20(address(usdc)), sh, shareOracle, address(pShare), CF_BPS, BORROW_CAP, CASH_FLOOR);
        usdc.mint(address(lender), POOL_CASH);
        atk = new FlashDonator(flash, IERC20(address(usdc)), proxyAddr, lender);
    }

    // =============================================================================================================================
    // (a) DONATION of USDC to the vault address, flash-funded: borrow power vs cost
    // =============================================================================================================================

    struct Out {
        uint256 shareValueOracle; // USDC-6, at the oracle price the lender uses
        uint256 shareValueExit; // USDC-6, pro-rata in-kind basket valued at the feeds
        uint256 borrowed;
        int256 attackerPnl; // USDC-6, shares abandoned to the lender
        uint256 lenderLoss; // USDC-6 shortfall of the exit value of the collateral vs the debt
        uint256 ta;
    }

    /// D = honest deposit made by the attacker first (0 = no shares, deposits closed); d = donation; flashAmt = part of d funded by the flash vault (0 when it could not be repaid)
    function _donationAttack(uint256 D, uint256 d, uint256 flashAmt) internal returns (Out memory o) {
        if (D != 0) {
            usdc.mint(address(atk), D);
            atk.depositOwn(D);
        }
        uint256 shares = sh.balanceOf(address(atk));
        // the borrow the attacker can take AFTER the donation (the donation happens first inside the callback): same arithmetic as the lender, on a snapshot
        uint256 snap = vm.snapshotState();
        usdc.mint(proxyAddr, d);
        uint256 b = _borrowPower(shares);
        vm.revertToState(snap);
        uint256 maxCash = POOL_CASH > CASH_FLOOR ? POOL_CASH - CASH_FLOOR : 0;
        if (b > BORROW_CAP - 1) b = BORROW_CAP - 1;
        if (b > maxCash) b = maxCash;
        if (flashAmt > b) flashAmt = 0; // a flash loan that cannot be repaid out of the borrow reverts: the attacker funds the donation himself
        uint256 own = d - flashAmt;
        usdc.mint(address(atk), own);
        o.borrowed = b;
        atk.run(flashAmt, d, b);
        o.ta = _ta();
        uint256 lc = sh.balanceOf(address(lender));
        o.shareValueOracle = lender.value18(lc) / 1e12;
        (uint256 cu, uint256 ct) = lc == 0 ? (0, 0) : _inKindProbe(address(lender), lc);
        o.shareValueExit = _atFeeds(cu, ct);
        // total outlay from the attacker's pocket = D (deposit) + own (part of the donation); he walks away from the shares
        o.attackerPnl = int256(usdc.balanceOf(address(atk))) - int256(D) - int256(own);
        o.lenderLoss = lender.debt(address(atk)) > o.shareValueExit ? lender.debt(address(atk)) - o.shareValueExit : 0;
    }

    function _log(string memory tag, uint256 D, uint256 d, Out memory o) internal pure {
        console2.log(tag);
        console2.log("  attacker deposit D (USDC-6):", D);
        console2.log("  donation d (USDC-6):", d);
        console2.log("  vault TA after (USDC-6):", o.ta);
        console2.log("  collateral value at oracle:", o.shareValueOracle);
        console2.log("  collateral value on exit  :", o.shareValueExit);
        console2.log("  borrowed:", o.borrowed);
        console2.log("  attacker P&L (negative = loss), USDC-6:");
        console2.logInt(o.attackerPnl);
        console2.log("  lender loss:", o.lenderLoss);
    }

    function test_A1_donation_flash_funded_open_deposits() public {
        // deposits open: the attacker can buy shares up to the cap (about USD 183), then flash-donates the pool's 100 USDC
        uint256 D = v.maxDeposit(address(atk));
        assertGt(D, 180e6, "about 183 of room");
        Out memory o = _donationAttack(D, 100e6, 100e6);
        _log("A1 deposits open, flash donation 100", D, 100e6, o);
        assertLt(o.attackerPnl, 0, "the donation attack loses money");
        assertEq(o.lenderLoss, 0, "the lender is never short: the donated USDC is real value in the vault");
        // the oracle priced the donation (collateral above the cap) but the exit basket pays it back to the holder: oracle value <= exit value + 1
        assertLe(o.shareValueOracle, o.shareValueExit + 6, "NAV is realisable in kind (+6 wei of floor rounding)");
    }

    function test_A2_donation_deposits_closed_no_shares() public {
        // deposits closed (cap == TA): an outsider holds 0 shares, the donation buys nothing
        uint256 taNow = _ta();
        vm.prank(SAFE);
        v.setDepositCap(taNow);
        vm.expectRevert();
        this._tryDeposit(100e6);
        Out memory o = _donationAttack(0, 100e6, 100e6);
        _log("A2 deposits closed, flash donation 100, attacker holds no shares", 0, 100e6, o);
        assertEq(o.borrowed, 0, "no shares, no borrow power");
        assertLe(o.attackerPnl, 0, "attacker only loses the donation");
    }

    function _tryDeposit(uint256 a) external {
        _fund(ATTACKER, a);
        vm.prank(ATTACKER);
        IERC4626(proxyAddr).deposit(a, ATTACKER);
    }

    function test_A3_donation_grid_table() public {
        uint256[3] memory Ds = [uint256(0), 50e6, 183e6];
        uint256[4] memory ds = [uint256(0), 10e6, 100e6, 500e6];
        for (uint256 i; i < Ds.length; ++i) {
            for (uint256 j; j < ds.length; ++j) {
                uint256 snap = vm.snapshotState();
                // each case on a clean fixture: fresh attacker contract state is the same, snapshot restores
                uint256 D = Ds[i];
                if (D > v.maxDeposit(address(atk))) D = v.maxDeposit(address(atk));
                uint256 fl = ds[j] > 100e6 ? 100e6 : ds[j];
                Out memory o = _donationAttack(D, ds[j], fl);
                console2.log("D / d / borrowed / pnl / lenderLoss");
                console2.log(D, ds[j], o.borrowed);
                console2.logInt(o.attackerPnl);
                console2.log(o.lenderLoss);
                assertLe(o.attackerPnl, 0, "never profitable");
                assertLe(o.lenderLoss, 2, "never a lender loss beyond 2 wei of dust (sub-share collateral cannot be exited in kind)");
                vm.revertToState(snap);
            }
        }
    }

    /// no donation size and no deposit size is profitable (formula: P = B - D - d, B <= CF * f * (TA + D + d), f = D/(TA + D) < 1, CF = 1/2)
    function testFuzz_A4_donation_never_profits(uint256 D, uint256 d) public {
        D = bound(D, 0, v.maxDeposit(address(atk)));
        d = bound(d, 0, 1_000_000_000e6);
        uint256 fl = d > 100e6 ? 100e6 : d;
        Out memory o = _donationAttack(D, d, fl);
        assertLe(o.attackerPnl, 0, "never profitable");
        assertLe(o.lenderLoss, 2, "never a lender loss beyond 2 wei of dust (sub-share collateral cannot be exited in kind)");
        assertLe(o.shareValueOracle, o.shareValueExit + 6, "NAV is realisable in kind (+6 wei of floor rounding)");
    }

    // =============================================================================================================================
    // (a') DONATION of USDt to the vault; (e) it also bypasses the deposit cap (idle balances are NAV)
    // =============================================================================================================================

    function test_A5_usdt_donation_counted_at_feed_and_blocks_deposits() public {
        uint256 ta0 = _ta();
        usdt.mint(address(this), 300e6);
        usdt.transfer(proxyAddr, 300e6);
        assertApproxEqAbs(_ta(), ta0 + 300e6, 1, "USDt donation counted at the feed price (par)");
        // the cap (USD 200) no longer limits collateral value: TA = 317 > cap; deposits are closed by the donation
        assertEq(v.maxDeposit(ATTACKER), 0, "maxDeposit 0 once TA >= cap");
        vm.expectRevert();
        this._tryDeposit(1e6);
        // the holders (operator 16/17 of supply) own the donation pro rata: nothing was extracted
        (uint256 cu, uint256 ct) = _inKindProbe(LEDGER, 16e6);
        assertApproxEqRel(_atFeeds(cu, ct), (ta0 + 300e6) * 16 / 17, 1e12, "exit pays the donation to share holders");
    }

    function test_A6_usdt_donation_at_depeg_overstates_by_the_discount() public {
        // the oracle values donated USDt at the feed; if USDt really trades at 99.0 % the donor pays 99 and the NAV counts 100: bounded by delta x d, no leverage
        usdt.mint(address(this), 100e6);
        usdt.transfer(proxyAddr, 100e6);
        uint256 realised = _atMarket(0, 100e6, 9_900);
        uint256 counted = 100e6;
        console2.log("donation counted (USDC-6) / real value at 99.0 % (USDC-6):", counted, realised);
        assertEq(counted - realised, 1e6, "overstatement = 1 % of the donated USDt");
    }

    // =============================================================================================================================
    // (b) DIRECT TRANSFER into the pair
    // =============================================================================================================================

    function test_B1_pair_donation_does_not_move_nav() public {
        uint256 ta0 = _ta();
        uint256 px0 = v.convertToAssets(1e6);
        uint256 pm0 = _shareMantissa();
        usdt.mint(address(this), 1_000e6);
        usdc.mint(address(this), 1_000e6);
        usdt.transfer(address(pair), 1_000e6);
        usdc.transfer(address(pair), 1_000e6);
        assertEq(_ta(), ta0, "totalAssets reads bin RESERVES (storage), not the pair's token balances");
        assertEq(v.convertToAssets(1e6), px0, "share price unchanged");
        assertEq(_shareMantissa(), pm0, "oracle price unchanged");
        // the donated tokens sit as balance - reserves: the NEXT swapper or minter consumes them
        (uint128 rx, uint128 ry) = pair.getReserves();
        assertEq(IERC20(pair.tokenX()).balanceOf(address(pair)) - rx, 1_000e6, "X in excess of reserves");
        assertEq(IERC20(pair.tokenY()).balanceOf(address(pair)) - ry, 1_000e6, "Y in excess of reserves");
    }

    function test_B2_pair_donation_is_swept_by_the_next_swapper_not_the_donor() public {
        usdt.mint(address(this), 1_000e6);
        usdt.transfer(address(pair), 1_000e6); // donated X (USDt)
        // an unrelated trader sells 1 USDt for USDC through the router: swap() reads amountIn = balance - reserve = 1,001 USDt
        address trader = address(0x7AAD);
        usdt.mint(trader, 1e6);
        uint256 before = usdc.balanceOf(trader);
        vm.startPrank(trader);
        usdt.approve(address(router), 1e6);
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(usdc);
        uint256[] memory steps = new uint256[](1);
        steps[0] = BIN_STEP;
        MockRouter.Version[] memory vers = new MockRouter.Version[](1);
        vers[0] = MockRouter.Version.V2_1;
        router.swapExactTokensForTokens(1e6, 0, MockRouter.Path(steps, vers, path), trader, block.timestamp + 1);
        vm.stopPrank();
        uint256 got = usdc.balanceOf(trader) - before;
        console2.log("trader sold 1 USDt after a 1,000 USDt donation to the pair, received USDC-6:", got);
        assertGt(got, 900e6, "the next swapper is credited the donation (up to the available depth)");
    }

    function test_B3_pair_donation_before_a_recentre_is_minted_to_the_vault() public {
        // a donated USDt sits in the pair until the vault's own addLiquidity mints (balance - reserves goes into the minted bins): the donor gifts the vault
        usdt.mint(address(this), 5e6);
        usdt.transfer(address(pair), 5e6);
        uint256 ta0 = _ta();
        // force the band out of range and let the keeper re-centre
        _pushOut(true);
        // vault NAV at oracle after the push (composition changed, tiny) then re-centre
        uint256 taPushed = _ta();
        _warpFresh(200);
        _rebalance();
        uint256 taAfter = _ta();
        console2.log("TA before donation-recentre / after push / after rebalance:", ta0, taPushed, taAfter);
        // the donated 5 USDt is now in the vault's bins or was swept by the market swaps; either way it is value, never a loss for holders
        assertGe(taAfter + 2e5, ta0, "no NAV loss beyond the bounded re-centre cost");
    }

    // =============================================================================================================================
    // (c) SWAPS through the pool: composition and NAV (oracle-marked)
    // =============================================================================================================================

    function test_C1_swap_sizes_vs_nav_and_attacker_cost() public {
        uint256[6] memory sizes = [uint256(10e6), 1_000e6, 10_000e6, 60_000e6, 150_000e6, 400_000e6];
        int256 worstNavUpBps;
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 i; i < sizes.length; ++i) {
                uint256 snap = vm.snapshotState();
                uint256 ta0 = _ta();
                uint256 px0 = v.convertToAssets(1e6);
                address who = address(0xA77AC);
                bool sellUsdc = dir == 0;
                uint256 inAmt = sizes[i];
                uint256 outAmt = _swapAs(who, sellUsdc, inAmt);
                uint256 ta1 = _ta();
                // the attacker's loss at par (both legs $1): in - out; the swap leaves the vault NAV change below
                int256 dNav = int256(ta1) - int256(ta0);
                console2.log(sellUsdc ? "SELL USDC size / navDelta(wei) / attackerLoss(wei) / activeId" : "SELL USDt size / navDelta(wei) / attackerLoss(wei) / activeId", inAmt);
                console2.logInt(dNav);
                console2.log(inAmt - outAmt, pair.getActiveId());
                int256 bps = dNav * 10_000 * 1e6 / int256(ta0); // bp x 1e6
                if (bps > worstNavUpBps) worstNavUpBps = bps;
                // attacker pays at least what the vault gains: NAV (oracle) rise is funded by the swapper's loss
                if (dNav > 0) assertLe(uint256(dNav), inAmt - outAmt, "vault NAV gain <= attacker loss");
                // share price moved by at most the band width (+-1 bin = 1 bp each side) plus fees: <= 4 bp
                assertLe(_bp(v.convertToAssets(1e6) > px0 ? v.convertToAssets(1e6) - px0 : 0, px0), 4, "share price rise <= 4 bp");
                vm.revertToState(snap);
            }
        }
        console2.log("worst NAV rise in bp x 1e6 across all swap sizes:", uint256(worstNavUpBps));
    }

    function test_C2_wash_trading_credits_fees_but_costs_more() public {
        uint256 ta0 = _ta();
        address who = address(0xA77AC);
        uint256 loss;
        for (uint256 i; i < 20; ++i) {
            uint256 o1 = _swapAs(who, true, 5_000e6);
            uint256 o2 = _swapAs(who, false, o1);
            loss += 5_000e6 - o2;
        }
        int256 dNav = int256(_ta()) - int256(ta0);
        console2.log("wash 20 round trips of 5,000: attacker loss / vault NAV delta (wei):", loss);
        console2.logInt(dNav);
        assertLe(dNav, int256(loss), "fees paid by the attacker exceed what the vault earns from them");
    }

    // =============================================================================================================================
    // (d) deposit -> borrow -> redeem sandwiches around a re-centre and a harvest
    // =============================================================================================================================

    function test_D1_deposit_then_redeem_around_recentre_is_not_free() public {
        uint256 D = 150e6;
        address a = ATTACKER;
        uint256 s = _dep(a, D);
        uint256 navBefore = _ta();
        _pushOut(true);
        _warpFresh(200);
        _rebalance();
        uint256 navAfter = _ta();
        // exit USDC-out right after
        vm.prank(a);
        uint256 got = IERC4626(proxyAddr).redeem(s, a, a);
        console2.log("deposit / NAV before re-centre / NAV after / USDC-out received:", D, navBefore, navAfter);
        console2.log("received:", got);
        assertLe(got, D + 5, "no profit from the sandwich");
    }

    function test_D2_re_centre_sandwich_attacker_pnl() public {
        // attacker front-runs the keeper (pushes the price out of the band), the keeper re-centres, the attacker back-runs by swapping the reverse amount
        uint256 taBefore = _ta();
        address who = address(0xA77AC);
        uint256 usdcBefore = 5_000_000e6;
        usdc.mint(who, usdcBefore);
        uint256 startValue = usdc.balanceOf(who) + usdt.balanceOf(who);
        uint256 usdtGot;
        {
            // push up: sell USDC for USDt until the band is left
            uint256 spent;
            (uint24 lo, uint24 hi,,,) = v.bandState();
            uint256 guard;
            while (guard++ < 50) {
                uint24 act = pair.getActiveId();
                if (act > hi || act < lo) break;
                spent += 40_000e6;
                usdtGot += _swapAs(who, true, 40_000e6);
            }
        }
        _warpFresh(200);
        _rebalance();
        // back-run: swap everything back
        if (usdt.balanceOf(who) != 0) _swapAs(who, false, usdt.balanceOf(who));
        uint256 endValue = usdc.balanceOf(who) + usdt.balanceOf(who);
        console2.log("sandwich: attacker value before / after (USDC-6):", startValue, endValue);
        console2.log("vault NAV before / after:", taBefore, _ta());
        assertLe(endValue, startValue, "the sandwich loses for the attacker (pool depth >> the vault's trade)");
    }

    function test_D3_harvest_does_not_move_nav() public {
        uint256 ta0 = _ta();
        phar.mint(proxyAddr, 1_000e18); // donated / claimed PHAR: not part of NAV
        vm.prank(KEEPER);
        v.harvestRewards();
        assertEq(_ta(), ta0, "PHAR is excluded from NAV and forwarded to the owner");
        assertEq(phar.balanceOf(SAFE), 1_000e18, "harvest forwards the whole PHAR balance");
    }

    // =============================================================================================================================
    // (e) supply floor, cap and idle-balance mechanics
    // =============================================================================================================================

    function test_E1_dead_seed_is_the_supply_floor() public {
        // everyone redeemable leaves in kind: the dead seed (1 share) keeps the supply at 1e6 and the price defined
        vm.prank(LEDGER);
        v.redeemInKind(16e6, LEDGER, LEDGER);
        assertEq(_supply(), 1e6, "supply floor = the dead seed");
        assertApproxEqAbs(v.convertToAssets(1e6), 1e6, 20, "price still about par (0.9999 after the band-open swap cost)");
        // a deposit may not leave 0 < supply < 1e6 (not the case here), and dust cannot be left by an entry
        uint256 s = _dep(ALICE, 1e6);
        assertGt(s, 0);
    }

    function test_E2_no_24h_lock_exists_in_the_vault() public {
        // deposit and redeem in the same block: nothing in the vault delays an exit or an entry (there is NO 24 h mechanic in the code; the nearest are maxFeedAge 93,600 s and the daily rebalance counter)
        uint256 s = _dep(BOB, 10e6);
        vm.prank(BOB);
        (uint256 ax, uint256 ay) = v.redeemInKind(s, BOB, BOB);
        assertGt(ax + ay, 9e6, "same-block in-kind exit works");
    }

    function test_E3_deposit_cap_binds_entries_only() public {
        uint256 room = v.maxDeposit(ATTACKER);
        _fund(ATTACKER, room + 1e6);
        vm.prank(ATTACKER);
        vm.expectRevert();
        IERC4626(proxyAddr).deposit(room + 1e6, ATTACKER);
        // but TA can exceed the cap by donation (A5) and by the market itself: cap is NOT a bound on collateral value
        usdc.mint(proxyAddr, 500e6);
        assertGt(_ta(), CAP, "TA above the cap by donation");
    }

    // =============================================================================================================================
    // (f) share price DROPS and NAV that overstates the exit
    // =============================================================================================================================

    function test_F1_usdt_depeg_overstatement_vs_cf_and_incentive() public {
        // worst case composition: band out of range on the USDt side = 100 % USDt; or 50 / 50 after a re-centre
        // overstatement ratio = real / oracle value = 1 - w x delta (USDt weight w, real discount delta; feed lagging at par)
        uint256[3] memory w = [uint256(5_000), 8_000, 10_000];
        uint256[4] memory delta = [uint256(100), 500, 1_000, 4_000];
        console2.log("USDt weight bp / real USDt discount bp / exit/oracle ratio bp / lender safe? (ratio*108% >= CF)");
        for (uint256 i; i < w.length; ++i) {
            for (uint256 j; j < delta.length; ++j) {
                uint256 ratio = 10_000 - w[i] * delta[j] / 10_000;
                // a max-borrowed position has debt = CF x oracle value; after liquidation the seized collateral is worth 1.08 x repaid debt at the ORACLE price,
                // so it pays the liquidator when real/oracle >= CF x 1.08 ... which is the threshold printed below
                bool safe = ratio * 10_000 >= CF_BPS * LIQ_INCENTIVE_BPS;
                console2.log(w[i], delta[j], ratio);
                console2.log(safe ? "  safe" : "  BAD DEBT");
            }
        }
        // threshold: 1 - w delta = 0.5 x 1.08 = 0.54  ->  w delta <= 46 %
        assertTrue((10_000 - 10_000 * 4_000 / 10_000) * 10_000 >= CF_BPS * LIQ_INCENTIVE_BPS, "w=100%, delta=40% still clears");
    }

    function test_F2_stale_feed_makes_the_share_price_zero_which_freezes_the_account() public {
        assertGt(_shareMantissa(), 0);
        // the vault reverts FeedInvalid when either feed is older than maxFeedAge 93,600 s; the wrapper then returns 0
        vm.warp(block.timestamp + 93_601);
        feedUsdc.setUpdatedAt(block.timestamp); // USDC feed fresh
        // USDt feed stale
        vm.expectRevert();
        v.totalAssets();
        assertEq(_shareMantissa(), 0, "wrapper: 0 on any vault revert -> controller returns PRICE_ERROR for every account that entered the market (borrow, redeem AND liquidation blocked)");
        // wrapper's own staleness window on the USDC feed (90,000 s) is separate: with the USDC feed stale the price is 0 too
        _refreshFeeds();
        assertGt(_shareMantissa(), 0, "fresh feeds restore the price");
        vm.warp(block.timestamp + 90_001);
        feedUsdt.setUpdatedAt(block.timestamp);
        assertEq(_shareMantissa(), 0, "USDC feed older than 90,000 s -> 0");
    }

    function test_F3_hook_down_exit_blocked_nav_unchanged() public {
        // a failing Pharaoh rewarder/hook reverts pair.burn: NAV (storage reads) keeps pricing the shares while neither redeemInKind nor redeem can pay: NAV not realisable
        uint256 p0 = _shareMantissa();
        rewarder.setRevert(false, false, true);
        assertEq(_shareMantissa(), p0, "oracle price unchanged while the hook is down");
        vm.prank(LEDGER);
        vm.expectRevert();
        v.redeemInKind(1e6, LEDGER, LEDGER);
        (, , uint256 reasons) = v.guardState();
        assertEq(reasons & 32, 0, "hook REVERTING (not unlinking) is not even flagged by the guard (bit 32 is for unlinked / codehash)");
        // an unlinked rewarder IS flagged: share price still read, bit 32 set
        // (documented, not asserted on the mock: unlink knob is pair.setHooksParameters(0))
        pair.setHooksParameters(bytes32(0));
        (, , reasons) = v.guardState();
        assertTrue(reasons & 32 != 0, "unlinked hook sets guard bit 32");
        assertEq(_shareMantissa(), p0, "but the wrapper still prices the share at NAV (it does not read guardState)");
    }

    function test_F4_trip_guard_is_permissionless_and_latches() public {
        // pool price pushed past the 60 bp band (fixture: forceActiveId, no trading cost modelled; in the real pool the cost is the depth walked) then ANYONE latches the vault
        // POOL_ORACLE_DEVIATION (16) is live-only and NOT latchable: tripGuard needs a latchable reason (feed or leg band). Show that tripGuard reverts on a pool-only deviation.
        pair.forceActiveId(uint24(ID0 + 90));
        (, , uint256 r) = v.guardState();
        assertTrue(r & 16 != 0, "pool deviation flagged live");
        vm.expectRevert();
        v.tripGuard();
        // a leg out of band (USDt feed at 0.99) IS latchable by anyone: and the vault stays latched after the feed recovers until the owner clears
        feedUsdt.setAnswer(99_000_000);
        v.tripGuard();
        feedUsdt.setAnswer(100_000_000);
        (, bool latched,) = v.guardState();
        assertTrue(latched, "latched until the owner clears");
        // the exit path is unaffected and NAV still reads
        assertGt(_ta(), 16e6);
    }

    function test_F5_forced_recentres_drain_bound() public {
        // worst-case NAV bleed per forced re-centre is capped by _checkNavLoss (50 bp of NAV) and the swap floor; measure the real mock number for a minimal push
        uint256 ta0 = _ta();
        _pushOut(false);
        _warpFresh(200);
        _rebalance();
        uint256 loss = ta0 > _ta() ? ta0 - _ta() : 0;
        console2.log("TA before / after one forced re-centre / loss (wei):", ta0, _ta(), loss);
        assertLe(loss * 10_000 / ta0, 50, "<= maxRebalanceLossBps");
    }

    function test_F6_feed_glitch_is_not_blocked_by_the_vault_guard_and_prices_into_the_share() public {
        // a Chainlink USDT/USD answer of 3.00 (glitch, still fresh): the vault guard FLAGS it (pair leg out of band, bit 8) but totalAssets() / convertToAssets keep pricing it,
        // so the wrapper's share price rises with the USDt weight. Break-even for an attacker needs the collateral overstated 2x: glitch factor g >= 1 + 1/w.
        uint256 p0 = _shareMantissa();
        (uint256 cu, uint256 ct) = _holdingsAtPair();
        uint256 w = _bp(ct, cu + ct); // USDt weight of the vault's inventory, bp
        feedUsdt.setAnswer(300_000_000);
        (, , uint256 reasons) = v.guardState();
        assertTrue(reasons & 8 != 0, "vault flags the USDt leg out of band");
        uint256 p1 = _shareMantissa();
        console2.log("USDt weight bp / price before / price after a 3.00 USDT feed answer:", w, p0, p1);
        assertGt(p1, p0, "NAV (and the wrapper price) rises with the glitch: guard bits gate entries, not the share price");
        assertLt(p1, 2 * p0, "but only by w x (g-1): below 2x while w < 100 %");
        // entries are closed by the guard, exits are not
        vm.expectRevert();
        this._tryDeposit(1e6);
    }

    // =============================================================================================================================
    // (g) the NAV is realisable: share-by-share, after arbitrary mixed actions (fuzz)
    // =============================================================================================================================

    function testFuzz_G1_nav_never_exceeds_in_kind_exit(uint256 a0, uint256 a1, uint256 a2, uint256 a3) public {
        // random mix: honest deposit, USDC donation, USDt donation, donation to the pair, a market swap, optionally a re-centre
        address who = ATTACKER;
        uint256 D = bound(a0, 1e6, 150e6);
        _dep(who, D);
        uint256 dUsdc = bound(a1, 0, 300e6);
        uint256 dUsdt = bound(a2, 0, 300e6);
        usdc.mint(proxyAddr, dUsdc);
        usdt.mint(proxyAddr, dUsdt);
        usdt.mint(address(this), bound(a3, 0, 100e6));
        usdt.transfer(address(pair), usdt.balanceOf(address(this)));
        uint256 swapSz = bound(a3 >> 8, 1e6, 80_000e6);
        _swapAs(address(0x5AAB), (a3 & 1) == 1, swapSz);
        if (_bandOut()) {
            _warpFresh(200);
            bytes memory cd = _rebalanceCall();
            vm.prank(KEEPER);
            (bool ok,) = proxyAddr.call(cd);
            ok; // a guard-unsafe or loss-capped revert is fine, only state matters
        }
        uint256 s = sh.balanceOf(who);
        uint256 navClaim = v.convertToAssets(s);
        (uint256 cu, uint256 ct) = _inKindProbe(who, s);
        uint256 exitAtFeeds = _atFeeds(cu, ct);
        // allow a few wei of rounding per bin (floor on both sides)
        assertLe(navClaim, exitAtFeeds + 6, "NAV claimed by the shares <= in-kind exit valued at the same feeds (+6 wei)");
        // and the oracle's whole-share price is consistent with the pro-rata claim
        assertLe(_oracleValueUsd18(s) / 1e12, exitAtFeeds + 6 + s / 1e6 + 2, "oracle value <= exit + rounding");
    }
}
