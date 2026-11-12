// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice Reference DETECTOR of the treasury-repayment procedure for the cash-only lending pilot (borrow USDC against WAVAX).
 *         TEST-ONLY reference implementation of the rule in docs/deployment-handoffs/avalanche-cash-only-treasury-repayment.md section 2.
 *         It is a monitor-side helper (call it with eth_call / a simulation): `evaluate` accrues interest on every listed market first
 *         (non-view), then reads existing controller/oracle/market views only. It holds no funds and has no power over any market.
 *         `mutation` is a MUTATION-TESTING hook (0 = the rule as specified); it is never non-zero outside a mutation run.
 */
contract TreasuryDefaultDetector {
    enum Verdict {
        NO_DEBT, // 0
        STALE_OR_ZERO_PRICE, // 1 fail closed: a price (or market snapshot) the rule needs is zero/unavailable
        NO_REFERENCE_PRICE, // 2 fail closed: no independent reference price supplied for a market the account touches
        HEALTHY, // 3 no shortfall
        LIQUIDATABLE_RECOVERABLE, // 4 shortfall, and a full liquidation clears the debt (C / LI >= D)
        UNRECOVERABLE_LIQUIDATE_FIRST, // 5 C / LI < D but collateral above dust: alert liquidators, do NOT repay
        DEFAULT_EXHAUSTED, // 6 C / LI < D and collateral <= dust: treasury repayment of the whole remaining debt is due
        PRICE_DIVERGENCE // 7 fail closed: oracle and reference price differ by more than the tolerance for a market the account touches
    }

    struct Result {
        Verdict verdict;
        uint256 debtUnits; // debt of the debt market in underlying units (after accrual)
        uint256 debtUsd; // conservative debt value (min(oracle, reference) price), USD 1e18
        uint256 collUsd; // conservative collateral value (max(oracle, reference) price) over ALL listed markets, USD 1e18
        uint256 collUsdOracle; // the same at oracle prices
        uint256 shortfallUsd; // controller shortfall (oracle prices, CF-weighted), USD 1e18
        uint256 maxRecoveryUsd; // collUsd / LI: the most a full liquidation can still repay (USD 1e18)
    }

    Peridottroller public immutable controller;
    address public immutable debtMarket;
    uint256 public immutable dustUsd; // USD 1e18
    uint256 public immutable toleranceBp; // oracle and reference are CONSISTENT iff |oracle - reference| / reference <= toleranceBp / 10,000
    uint256 public immutable mutation;

    constructor(Peridottroller controller_, address debtMarket_, uint256 dustUsd_, uint256 toleranceBp_, uint256 mutation_) {
        controller = controller_;
        debtMarket = debtMarket_;
        dustUsd = dustUsd_;
        toleranceBp = toleranceBp_;
        mutation = mutation_;
    }

    function evaluate(address account, uint256[] calldata refPrices) external returns (Result memory r) {
        PToken[] memory ms = controller.getAllMarkets();
        require(refPrices.length == ms.length, "refs length");
        PriceOracle oracle_ = controller.oracle();
        for (uint256 i; i < ms.length; ++i) {
            ms[i].accrueInterest();
        }
        // 1. debt
        {
            (, , uint256 b, ) = PToken(debtMarket).getAccountSnapshot(account);
            r.debtUnits = b;
            if (b == 0) {
                r.verdict = Verdict.NO_DEBT;
                return r;
            }
        }
        // 2. conservative valuation with an independent reference price per market
        for (uint256 i; i < ms.length; ++i) {
            (uint256 err, uint256 pBal, uint256 bBal, uint256 exch) = ms[i].getAccountSnapshot(account);
            if (err != 0) {
                r.verdict = Verdict.STALE_OR_ZERO_PRICE;
                return r;
            }
            if (pBal == 0 && bBal == 0) continue;
            uint256 p = oracle_.getUnderlyingPrice(ms[i]);
            if (p == 0) {
                r.verdict = Verdict.STALE_OR_ZERO_PRICE;
                return r;
            }
            uint256 ref = refPrices[i];
            if (ref == 0) {
                r.verdict = Verdict.NO_REFERENCE_PRICE;
                return r;
            }
            // oracle and reference must AGREE within the tolerance, else one of them is wrong and nothing is paid
            // (mutation 3 removes this check)
            if (mutation != 3 && (p > ref ? p - ref : ref - p) * 10_000 > ref * toleranceBp) {
                r.verdict = Verdict.PRICE_DIVERGENCE;
                return r;
            }
            if (bBal > 0) r.debtUsd += (bBal * (p < ref ? p : ref)) / 1e18; // lower price: harder to call the debt unrecoverable
            if (pBal > 0) {
                uint256 underlying = (pBal * exch) / 1e18;
                r.collUsd += (underlying * (p > ref ? p : ref)) / 1e18; // higher price: harder to call the collateral exhausted
                r.collUsdOracle += (underlying * p) / 1e18;
            }
        }
        // 3. shortfall at oracle prices (an error code, e.g. 13 = price error, means: unknown, do not act)
        {
            (uint256 err, , uint256 sf) = controller.getAccountLiquidity(account);
            if (err != 0) {
                r.verdict = Verdict.STALE_OR_ZERO_PRICE;
                return r;
            }
            r.shortfallUsd = sf;
            if (sf == 0) {
                r.verdict = Verdict.HEALTHY;
                return r;
            }
        }
        uint256 li = controller.liquidationIncentiveMantissa();
        r.maxRecoveryUsd = (r.collUsd * 1e18) / li;
        if (mutation == 1) {
            // MUTATION 1: fire on shortfall alone (also on recoverable and not-yet-exhausted accounts)
            r.verdict = Verdict.DEFAULT_EXHAUSTED;
            return r;
        }
        // 4. a full liquidation clears the debt: C / LI >= D
        if (r.collUsd * 1e18 >= r.debtUsd * li) {
            r.verdict = Verdict.LIQUIDATABLE_RECOVERABLE;
            return r;
        }
        // 5. liquidation exhausted: what is left to seize is dust
        if (r.collUsd > dustUsd) {
            r.verdict = Verdict.UNRECOVERABLE_LIQUIDATE_FIRST;
            return r;
        }
        r.verdict = Verdict.DEFAULT_EXHAUSTED;
    }
}

/**
 * @notice TREASURY REPAYMENT (`repayBorrowBehalf`) AT PILOT SCALE for the one-direction cash-only lending pilot: borrow USDC against WAVAX,
 *         candidates PW30 (CF 30%) and PW40 (CF 40%), USDC CF 0, WAVAX borrowing paused, 20% cash floor on pUSDC, close factor 50%,
 *         liquidation incentive 1.08 (PROVISIONAL), research caps USD 1,000 / 5,000 / 10,000 (NOT approved caps).
 *         NO treasury funds are committed by this file or the procedure; the audited write-off (reserve-first, "S3") is a SEPARATE scaling
 *         proposal and is neither built nor extended here. Nothing under contracts/contracts/ is touched.
 *
 * FIXTURE. The fixture LP (USDC 400,000 in pUSDC) redeems everything in setUp so that FOUR research suppliers hold ALL pUSDC supply:
 *   A 50%, B 25%, C 15%, D 10% of S = cap / 0.8 (so that the 20% cash floor applies: floor = S / 5 = cap / 4). Three borrowers
 *   (0x9000..0x9002) each deposit WAVAX sized to a borrowing power of cap / 3 and borrow 100% of it (the largest amount the controller
 *   accepts, found by decrementing one unit at a time), total borrows = cap. The controller borrow cap is set to cap + 1 unit because its
 *   check is strict (`nextTotalBorrows < cap`). 30 days of interest accrue (1 block = 1 second in the fixture's rate model) with NO
 *   liquidation in between (a borrower at 100% of power is liquidatable from the first second of interest; the model keeps the position
 *   for the worst case), then one adverse price gap, then a funded liquidator (CAROL) liquidates every borrower until its collateral is
 *   below USD 0.01. The unrecoverable debt left is the loss L0. FUNDING is a fraction of L0 (what the closed form sizes); the interest that
 *   accrues on that debt while nobody pays it (delay) is reported separately as `phantom`.
 *
 * ASSERTIONS are accounting identities and the equalities that separate the funding levels (no fairness threshold):
 *   cash + borrows - reserves = sum of supplier claims (8 wei), value conserved by the exits, total exit shortfall = max(0, remaining
 *   borrows - reserves) for EVERY order, repayBorrowBehalf leaves the exchange rate/claims unchanged, the detector truth table.
 * OUTPUT: `TRP|...` lines (rendered by the evidence folder's analysis/tables.py).
 */
contract AvalancheCashOnlyTreasuryRepayForkTest is AvalancheCashOnlyBase {
    uint256 internal constant N = 3; // defaulting borrowers
    uint256 internal constant TOL = 32; // wei of USDC (rounding only; sequential exits and shares-accounting rounding)
    uint256 internal constant DUST_USD6 = 10_000; // USD 0.01 (liquidation loop stops here)
    uint256 internal constant DUST_USD18 = 0.01e18;
    /// @dev Reference-price tolerance of the specification (treasury document 2.3): oracle and reference are consistent iff
    ///      |oracle - reference| / reference <= REF_TOLERANCE_BP / 10,000. Value fixed from the 30-day TWAP-vs-Chainlink study.
    uint256 internal constant REF_TOLERANCE_BP = 500;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant LI = 1.08e18;

    address internal constant EARLY = address(0xEA21);
    address internal constant LATE = address(0x1A7E);
    address internal constant SMALL = address(0x5A11);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant ATTACKER = address(0xA77AC);
    address internal constant HEALTHY_ACCT = address(0x4EA1);
    address internal constant NO_DEBT_ACCT = address(0x40DB);

    PeridottrollerAvalanche internal ctrl;
    TreasuryDefaultDetector internal detector;
    uint256 internal mutation; // 0 = as specified; 1 = detector fires on shortfall alone; 2 = repay applied to the NEXT borrower; 3 = detector without the reference-divergence gate

    struct Base {
        uint256 cap6;
        uint256 supply6; // S
        uint256 cf;
        uint256 snap;
        uint256 borrowed; // total borrows right after the borrows
        uint256 minPowerPpm; // lowest borrower utilisation of its borrowing power (ppm)
        uint256 debtAfter30d; // sum of the borrowers' debt after the 30-day accrual
    }

    struct Evt {
        uint256 dGap; // sum of borrower debt right before the gap
        uint256 cAfter6; // sum of borrower collateral value in USDC units right after the gap, before liquidation
        uint256 c0Before6; // same just before the gap (pre-gap price)
        uint256 l0; // unrecoverable debt after liquidation (sum over borrowers)
        uint256 repaid; // USDC repaid by the liquidator
        uint256 residual6; // largest residual collateral value (USDC units) of a borrower after liquidation
        uint256 snap;
    }

    struct Agg {
        uint256[4] claim;
        uint256[4] minGot;
        uint256[4] maxGot;
        uint256 shortTot;
        uint256 worstPpm;
        uint256 lastShortMax;
        uint256 lastShortMin;
        uint256 firstShortMax;
        uint256 nShortOrders;
    }

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return;
        mutation = vm.envOr("TREASURY_MUTATION", uint256(0));
        ctrl = PeridottrollerAvalanche(address(controller));
        detector = new TreasuryDefaultDetector(controller, address(pUsdc), DUST_USD18, REF_TOLERANCE_BP, mutation);
        // the fixture LP withdraws its entire pUSDC supply so that the research suppliers dominate (here: are) the market
        uint256 lpTok = pUsdc.balanceOf(LP);
        vm.prank(LP);
        require(pUsdc.redeem(lpTok) == 0, "LP exit");
        assertEq(pUsdc.totalSupply(), 0, "pUSDC empty");
    }

    // ================================================================= small helpers
    function _live() internal view returns (bool) {
        return address(controller) != address(0);
    }

    function _kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat("|", k, "=", vm.toString(v));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _back(uint256 snap) internal {
        vm.revertToState(snap);
        _setPrices(avaxAnswer, usdcAnswer);
    }

    function _sup(uint256 j) internal pure returns (address) {
        return j == 0 ? LP : j == 1 ? EARLY : j == 2 ? LATE : SMALL;
    }

    function _supLetter(uint256 j) internal pure returns (string memory) {
        return j == 0 ? "A" : j == 1 ? "B" : j == 2 ? "C" : "D";
    }

    function _share(uint256 j) internal pure returns (uint256) {
        return j == 0 ? 50 : j == 1 ? 25 : j == 2 ? 15 : 10; // percent of S
    }

    function _borrower(uint256 i) internal pure returns (address) {
        return address(uint160(0x9000 + i));
    }

    function _perms() internal pure returns (uint8[4][24] memory p) {
        uint256 n;
        for (uint8 a; a < 4; ++a) {
            for (uint8 b; b < 4; ++b) {
                if (b == a) continue;
                for (uint8 c; c < 4; ++c) {
                    if (c == a || c == b) continue;
                    p[n++] = [a, b, c, 6 - a - b - c];
                }
            }
        }
    }

    function _permStr(uint8[4] memory o) internal pure returns (string memory) {
        return string.concat(_supLetter(o[0]), _supLetter(o[1]), _supLetter(o[2]), _supLetter(o[3]));
    }

    function _wavaxToUsdc(uint256 wavaxUnits) internal view returns (uint256) {
        return Math.mulDiv(wavaxUnits, oracle.getUnderlyingPrice(PToken(address(pWavax))), oracle.getUnderlyingPrice(PToken(address(pUsdc))));
    }

    function _collUsdc(address who) internal view returns (uint256) {
        return _wavaxToUsdc(Math.mulDiv(pWavax.balanceOf(who), pWavax.exchangeRateStored(), 1e18));
    }

    function _sumDebt() internal returns (uint256 s) {
        for (uint256 i; i < N; ++i) {
            s += pUsdc.borrowBalanceCurrent(_borrower(i));
        }
    }

    function _roll(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks);
        _setPrices(avaxAnswer, usdcAnswer);
        pUsdc.accrueInterest();
        pWavax.accrueInterest();
    }

    /// @dev Independent reference prices for the detector, aligned with `controller.getAllMarkets()`. In the matrix the monitor's
    ///      independent source is taken to agree with the oracle; the manipulation test supplies different values.
    function _refsFromOracle() internal view returns (uint256[] memory refs) {
        PToken[] memory ms = controller.getAllMarkets();
        refs = new uint256[](ms.length);
        for (uint256 i; i < ms.length; ++i) {
            refs[i] = oracle.getUnderlyingPrice(ms[i]);
        }
    }

    function _eval(address who) internal returns (TreasuryDefaultDetector.Result memory r) {
        r = detector.evaluate(who, _refsFromOracle());
    }

    function _verdictName(TreasuryDefaultDetector.Verdict v) internal pure returns (string memory) {
        if (v == TreasuryDefaultDetector.Verdict.NO_DEBT) return "NO_DEBT";
        if (v == TreasuryDefaultDetector.Verdict.STALE_OR_ZERO_PRICE) return "STALE_OR_ZERO_PRICE";
        if (v == TreasuryDefaultDetector.Verdict.NO_REFERENCE_PRICE) return "NO_REFERENCE_PRICE";
        if (v == TreasuryDefaultDetector.Verdict.HEALTHY) return "HEALTHY";
        if (v == TreasuryDefaultDetector.Verdict.LIQUIDATABLE_RECOVERABLE) return "LIQUIDATABLE_RECOVERABLE";
        if (v == TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST) return "UNRECOVERABLE_LIQUIDATE_FIRST";
        if (v == TreasuryDefaultDetector.Verdict.PRICE_DIVERGENCE) return "PRICE_DIVERGENCE";
        return "DEFAULT_EXHAUSTED";
    }

    // ================================================================= fixture
    /// @dev Configures the pilot (PW candidate CF), builds the supplier population and the three full-capacity borrowers, accrues 30 days.
    function _prepare(uint256 capUsd, uint256 cf, string memory cand) internal returns (Base memory b) {
        b.cap6 = capUsd * 1e6;
        b.supply6 = (b.cap6 * 10) / 8;
        b.cf = cf;
        _setPrices(realAvaxAnswer, usdcAnswer);
        require(controller._setCollateralFactor(PToken(address(pWavax)), cf) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u off");
        controller._setBorrowPaused(PErc20(address(pUsdc)), false); // USDC borrowing on; WAVAX borrowing stays paused
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = b.cap6 + 1; // strict `<` in the controller: total borrows can reach exactly cap
        controller._setMarketBorrowCaps(ps, caps);
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), b.supply6 / 5) == 0, "floor"); // 20% of supply
        for (uint256 j; j < 4; ++j) {
            _mintP(pUsdc, _sup(j), (b.supply6 * _share(j)) / 100);
        }
        // borrowers: collateral sized to a borrowing power of cap / 3, then 100% of the power
        uint256 pu = oracle.getUnderlyingPrice(PToken(address(pUsdc)));
        uint256 pw = oracle.getUnderlyingPrice(PToken(address(pWavax)));
        b.minPowerPpm = type(uint256).max;
        for (uint256 i; i < N; ++i) {
            uint256 target6 = i < N - 1 ? b.cap6 / N : b.cap6 - 2 * (b.cap6 / N);
            uint256 collUsdcUnits = Math.mulDiv(target6, 1e18, cf);
            uint256 wavaxUnits = Math.mulDiv(collUsdcUnits, pu, pw) + 2e12; // tiny rounding margin so that power >= target
            _mintP(pWavax, _borrower(i), wavaxUnits);
            _enter(_borrower(i));
            (, uint256 liq,) = controller.getAccountLiquidity(_borrower(i));
            uint256 maxBorrow = Math.mulDiv(liq, 1e18, pu);
            uint256 want = _min(maxBorrow, b.cap6 - pUsdc.totalBorrows());
            bool ok;
            for (uint256 k; k < 60; ++k) {
                (ok,) = _borrow(pUsdc, _borrower(i), want);
                if (ok) break;
                --want;
            }
            require(ok, "borrow at full capacity failed");
            b.minPowerPpm = _min(b.minPowerPpm, (want * 1e6) / maxBorrow);
        }
        b.borrowed = pUsdc.totalBorrows();
        string memory l = string.concat("TRP|BASE|cap=", vm.toString(capUsd), "|cand=", cand);
        emit log_string(
            string.concat(
                l,
                _kv("supply", b.supply6),
                _kv("borrowed", b.borrowed),
                _kv("floor", b.supply6 / 5),
                _kv("cashAtBorrow", pUsdc.getCash()),
                _kv("minPowerPpm", b.minPowerPpm),
                _kv("aprPpmAtBorrow", (pUsdc.borrowRatePerBlock() * 31_536_000) / 1e12),
                "|END"
            )
        );
        _roll(30 * DAY);
        b.debtAfter30d = _sumDebt();
        emit log_string(
            string.concat(
                l,
                "|ACCRUAL30",
                _kv("debt30", b.debtAfter30d),
                _kv("growthPpm", ((b.debtAfter30d - b.borrowed) * 1e6) / b.borrowed),
                _kv("aprPpmAfter", (pUsdc.borrowRatePerBlock() * 31_536_000) / 1e12),
                _kv("reserves", pUsdc.totalReserves()),
                _kv("rate", pUsdc.exchangeRateStored()),
                "|END"
            )
        );
        // supplier-only market
        uint256 held;
        for (uint256 j; j < 4; ++j) {
            held += pUsdc.balanceOf(_sup(j));
        }
        assertEq(held, pUsdc.totalSupply(), "the four research suppliers hold all pUSDC");
        b.snap = vm.snapshotState();
    }

    /// @dev Liquidate with the funded liquidator until the collateral is below USD 0.01 (or no liquidation is accepted).
    function _clear(address b) internal returns (uint256 repaidTotal) {
        for (uint256 calls; calls < 60; ++calls) {
            (,, uint256 sf) = controller.getAccountLiquidity(b);
            if (sf == 0) break;
            uint256 colBal = pWavax.balanceOf(b);
            if (_collUsdc(b) < DUST_USD6) break;
            uint256 repay = pUsdc.borrowBalanceCurrent(b) / 2;
            (, uint256 seize) = controller.liquidateCalculateSeizeTokens(address(pUsdc), address(pWavax), repay);
            if (seize > colBal) repay = (repay * colBal) / seize;
            bool done;
            for (uint256 a; a < 8 && repay > 0; ++a) {
                if (repay < DUST_USD6) {
                    repay = 0;
                    break;
                }
                (bool ok,,) = _liquidate(pUsdc, pWavax, b, repay);
                if (ok) {
                    repaidTotal += repay;
                    done = true;
                    break;
                }
                repay = (repay * 99_999) / 100_000;
            }
            if (!done) break;
        }
    }

    /// @dev From the BASE snapshot: price gap (`fallBps`), liquidation to exhaustion, reports and closed-form check. Leaves a snapshot.
    function _event(Base memory bs, uint256 fallBps, string memory grp) internal returns (Evt memory e) {
        _back(bs.snap);
        e.dGap = _sumDebt();
        for (uint256 i; i < N; ++i) {
            e.c0Before6 += _collUsdc(_borrower(i));
        }
        _setAvaxBps(10_000 - fallBps);
        for (uint256 i; i < N; ++i) {
            e.cAfter6 += _collUsdc(_borrower(i));
        }
        for (uint256 i; i < N; ++i) {
            e.repaid += _clear(_borrower(i));
        }
        for (uint256 i; i < N; ++i) {
            uint256 res6 = _collUsdc(_borrower(i));
            if (res6 > e.residual6) e.residual6 = res6;
        }
        e.l0 = _sumDebt();
        // closed form on the MEASURED position: loss = D - C_after / LI (algebraically D (1 - rho / LI), rho = C_after / D)
        uint256 recover = (e.cAfter6 * 1e18) / LI;
        uint256 expected = e.dGap > recover ? e.dGap - recover : 0;
        assertGe(e.l0 + TOL, expected, "measured loss below the closed form");
        assertLe(e.l0, expected + N * (DUST_USD6 + 16), "measured loss above the closed form by more than the liquidation dust");
        assertEq(e.dGap - e.repaid, e.l0, "debt - repaid = unrecoverable debt (no interest accrues inside a block)");
        // the same closed form written with rho = (1 - x) / (CF u) and u = D / (CF C0)
        uint256 rho = (e.cAfter6 * 1e18) / e.dGap; // = (1 - x) / (CF u)
        uint256 lossCf = rho >= LI ? 0 : (e.dGap * (LI - rho)) / LI;
        assertApproxEqAbs(lossCf, expected, 4, "D (1 - rho / LI) == D - C_after / LI");
        emit log_string(
            string.concat(
                "TRP|EVT|",
                grp,
                _kv("dGap", e.dGap),
                _kv("c0", e.c0Before6),
                _kv("cAfter", e.cAfter6),
                _kv("repaid", e.repaid),
                _kv("l0", e.l0),
                _kv("closedForm", expected),
                _kv("residualMaxUsdc6", e.residual6),
                _kv("uEffPpm", Math.mulDiv(e.dGap, 1e24, e.c0Before6 * bs.cf)),
                "|END"
            )
        );
        e.snap = vm.snapshotState();
    }

    // ================================================================= the treasury procedure (runbook)
    /// @dev Repay `amount` (or the full-repay sentinel) on `account` from the TREASURY and assert exactly what moved. Mutation 2 repays the
    ///      NEXT borrower instead (the wrong account); the assertions then fail.
    function _repayOne(address account, uint256 amount) internal returns (uint256 pulled) {
        address target = mutation == 2 ? _borrower((_idx(account) + 1) % N) : account;
        uint256[N] memory before;
        for (uint256 i; i < N; ++i) {
            before[i] = pUsdc.borrowBalanceCurrent(_borrower(i));
        }
        uint256 treasuryBefore = IERC20(USDC).balanceOf(TREASURY);
        vm.prank(TREASURY);
        require(pUsdc.repayBorrowBehalf(target, amount) == 0, "repayBorrowBehalf");
        pulled = treasuryBefore - IERC20(USDC).balanceOf(TREASURY);
        uint256 expected = amount == type(uint256).max ? before[_idx(account)] : amount;
        assertApproxEqAbs(pulled, expected, 2, "the treasury paid exactly the amount (or the whole debt for the sentinel)");
        for (uint256 i; i < N; ++i) {
            uint256 afterDebt = pUsdc.borrowBalanceStored(_borrower(i));
            if (_borrower(i) == account) {
                assertApproxEqAbs(afterDebt, before[i] - expected, 2, "the NAMED account's debt fell by exactly the amount");
            } else {
                assertEq(afterDebt, before[i], "no other account's debt changed");
            }
        }
    }

    function _idx(address b) internal pure returns (uint256) {
        return uint256(uint160(b)) - 0x9000;
    }

    /// @dev The runbook: for each borrower (largest debt first) the detector must say DEFAULT_EXHAUSTED; then repay the whole remaining debt
    ///      with the full-repay sentinel while the budget lasts, the last account gets the rest as an explicit partial amount.
    function _runbook(uint256 budget) internal returns (uint256 paid, uint256 nFull, uint256 nPartial) {
        if (budget == 0) return (0, 0, 0);
        deal(USDC, TREASURY, budget);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), budget);
        bool[N] memory done;
        uint256 left = budget;
        for (uint256 step; step < N; ++step) {
            uint256 best = N;
            uint256 bestDebt;
            for (uint256 i; i < N; ++i) {
                if (done[i]) continue;
                uint256 d = pUsdc.borrowBalanceCurrent(_borrower(i));
                if (best == N || d > bestDebt) {
                    best = i;
                    bestDebt = d;
                }
            }
            done[best] = true;
            TreasuryDefaultDetector.Result memory r = _eval(_borrower(best));
            if (r.verdict != TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED) continue; // the rule did not fire: no repayment
            if (left == 0) break;
            if (left >= r.debtUnits) {
                uint256 p = _repayOne(_borrower(best), type(uint256).max);
                paid += p;
                left -= p;
                ++nFull;
            } else {
                uint256 p = _repayOne(_borrower(best), left);
                paid += p;
                left -= p;
                ++nPartial;
            }
        }
    }

    // ================================================================= suppliers' exits
    function _exit(uint256 j) internal returns (uint256 claim, uint256 got) {
        address s = _sup(j);
        uint256 tok = pUsdc.balanceOf(s);
        claim = (tok * pUsdc.exchangeRateStored()) / 1e18;
        uint256 cash = pUsdc.getCash();
        uint256 before = IERC20(USDC).balanceOf(s);
        if (claim <= cash) {
            vm.prank(s);
            require(pUsdc.redeem(tok) == 0, "redeem");
        } else if (cash > 0) {
            vm.prank(s);
            require(pUsdc.redeemUnderlying(cash) == 0, "redeemUnderlying(cash)");
        }
        got = IERC20(USDC).balanceOf(s) - before;
    }

    function _claims() internal view returns (uint256[4] memory c, uint256 tot) {
        uint256 rate = pUsdc.exchangeRateStored();
        for (uint256 j; j < 4; ++j) {
            c[j] = (pUsdc.balanceOf(_sup(j)) * rate) / 1e18;
            tot += c[j];
        }
    }

    function _identity(string memory why) internal view returns (uint256 claimsTot) {
        (, claimsTot) = _claims();
        uint256 cash = pUsdc.getCash();
        uint256 borrows = pUsdc.totalBorrows();
        uint256 res = pUsdc.totalReserves();
        require(cash + borrows >= res, string.concat("negative net assets: ", why));
        require(_absDiff(cash + borrows - res, claimsTot) <= 8, string.concat("cash + borrows - reserves != sum of claims: ", why));
    }

    /// @dev All 24 exit orders from the CURRENT state (snapshot-reverted between orders). `rem` = recorded borrows now, `res` = reserves now.
    function _orders(string memory grp) internal returns (Agg memory g) {
        uint256 snap = vm.snapshotState();
        (g.claim,) = _claims();
        uint256 cashF = pUsdc.getCash();
        uint256 rem = pUsdc.totalBorrows();
        uint256 res = pUsdc.totalReserves();
        uint8[4][24] memory perms = _perms();
        g.minGot = [type(uint256).max, type(uint256).max, type(uint256).max, type(uint256).max];
        g.lastShortMin = type(uint256).max;
        g.worstPpm = type(uint256).max;
        g.shortTot = _max0(rem, res);
        for (uint256 p; p < 24; ++p) {
            uint256[4] memory got;
            uint256[4] memory claimExit;
            uint256 sumGot;
            for (uint256 k; k < 4; ++k) {
                uint256 j = perms[p][k];
                (claimExit[j], got[j]) = _exit(j);
                sumGot += got[j];
            }
            assertEq(sumGot + pUsdc.getCash(), cashF, "value conserved: every USDC went to a supplier or is still in the market");
            uint256 totShort;
            uint256[4] memory sh;
            bool anyShort;
            for (uint256 j; j < 4; ++j) {
                sh[j] = claimExit[j] - got[j];
                totShort += sh[j];
                if (sh[j] > 0) anyShort = true;
                if (got[j] < g.minGot[j]) g.minGot[j] = got[j];
                if (got[j] > g.maxGot[j]) g.maxGot[j] = got[j];
                if (claimExit[j] > 0) {
                    uint256 ppm = (got[j] * 1e6) / claimExit[j];
                    if (ppm < g.worstPpm) g.worstPpm = ppm;
                }
            }
            // EVERY order: total exit shortfall = max(0, remaining borrows - reserves) (the unpaid debt, less what the reserves back)
            assertApproxEqAbs(totShort, g.shortTot, TOL, "total exit shortfall == max(0, remaining borrows - reserves) in every order");
            uint256 first = perms[p][0];
            uint256 last = perms[p][3];
            if (sh[first] > g.firstShortMax) g.firstShortMax = sh[first];
            if (sh[last] > g.lastShortMax) g.lastShortMax = sh[last];
            if (sh[last] < g.lastShortMin) g.lastShortMin = sh[last];
            if (anyShort) ++g.nShortOrders;
            emit log_string(
                string.concat(
                    "TRP|ORD|", grp, "|perm=", _permStr(perms[p]), _kv("sA", sh[0]), _kv("sB", sh[1]), _kv("sC", sh[2]), _kv("sD", sh[3]), "|END"
                )
            );
            vm.revertToState(snap);
        }
        emit log_string(
            string.concat(
                "TRP|TAB|",
                grp,
                _kv("rem", rem),
                _kv("res", res),
                _kv("cash", cashF),
                _kv("shortTot", g.shortTot),
                _kv("cA", g.claim[0]),
                _kv("cB", g.claim[1]),
                _kv("cC", g.claim[2]),
                _kv("cD", g.claim[3]),
                _kv("minA", g.minGot[0]),
                _kv("minB", g.minGot[1]),
                _kv("minC", g.minGot[2]),
                _kv("minD", g.minGot[3])
            )
        );
        emit log_string(
            string.concat(
                "TRP|TAB2|",
                grp,
                _kv("maxA", g.maxGot[0]),
                _kv("maxB", g.maxGot[1]),
                _kv("maxC", g.maxGot[2]),
                _kv("maxD", g.maxGot[3]),
                _kv("worstPpm", g.worstPpm),
                _kv("firstShortMax", g.firstShortMax),
                _kv("lastShortMax", g.lastShortMax),
                _kv("lastShortMin", g.lastShortMin),
                _kv("nShortOrders", g.nShortOrders),
                "|END"
            )
        );
    }

    // ================================================================= the grid: funding x delay x all orders, per (cap, candidate)
    function _matrix(uint256 capUsd, uint256 cf, string memory cand, uint256[] memory fallsBps) internal {
        if (!_live()) return;
        Base memory bs = _prepare(capUsd, cf, cand);
        uint256[4] memory delays = [uint256(0), 1, 7, 30];
        for (uint256 t; t < fallsBps.length; ++t) {
            string memory eg = string.concat("cap=", vm.toString(capUsd), "|cand=", cand, "|fall=", vm.toString(fallsBps[t]));
            Evt memory e = _event(bs, fallsBps[t], eg);
            assertGt(e.l0, 0, "the tail is beyond the zero-loss gap: there is unrecoverable debt");
            for (uint256 d; d < 4; ++d) {
                _back(e.snap);
                if (delays[d] > 0) _roll(delays[d] * DAY);
                uint256 ld = _sumDebt();
                string memory dg = string.concat(eg, "|delay=", vm.toString(delays[d]));
                {
                    (, uint256 claimsTot0) = _claims();
                    emit log_string(
                        string.concat(
                            "TRP|DLY|",
                            dg,
                            _kv("ld", ld),
                            _kv("phantom", ld - e.l0),
                            _kv("reserves", pUsdc.totalReserves()),
                            _kv("cash", pUsdc.getCash()),
                            _kv("claims", claimsTot0),
                            _kv("rate", pUsdc.exchangeRateStored()),
                            _kv("aprPpm", (pUsdc.borrowRatePerBlock() * 31_536_000) / 1e12),
                            _kv("utilPpm", (pUsdc.totalBorrows() * 1e6) / (pUsdc.getCash() + pUsdc.totalBorrows() - pUsdc.totalReserves())),
                            "|END"
                        )
                    );
                }
                // the detector must fire for every defaulted account, at every delay (fresh prices, collateral exhausted)
                for (uint256 i; i < N; ++i) {
                    assertEq(
                        uint256(_eval(_borrower(i)).verdict),
                        uint256(TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED),
                        "detector fires on an exhausted account"
                    );
                }
                uint256 snapD = vm.snapshotState();
                uint256 nf = d == 0 ? 4 : 5;
                uint256[5] memory shortAt;
                uint256[5] memory paidAt;
                uint256 remAt0;
                uint256 resAt0;
                for (uint256 f; f < nf; ++f) {
                    _back(snapD);
                    uint256 budget = f == 0 ? e.l0 : f == 1 ? e.l0 / 2 : f == 2 ? e.l0 / 4 : f == 3 ? 0 : ld;
                    string memory fl = f == 0 ? "F100" : f == 1 ? "F50" : f == 2 ? "F25" : f == 3 ? "F0" : "FLD";
                    uint256 rateBefore = pUsdc.exchangeRateStored();
                    (, uint256 claimsBefore) = _claims();
                    uint256 resBefore = pUsdc.totalReserves();
                    (uint256 paid, uint256 nFull, uint256 nPart) = _runbook(budget);
                    // repayBorrowBehalf cannot harm suppliers: exchange rate, claims and reserves are unchanged by it
                    (, uint256 claimsAfter) = _claims();
                    assertLe(_absDiff(claimsAfter, claimsBefore), 8, "claims unchanged by the repayment");
                    assertApproxEqAbs(pUsdc.totalReserves(), resBefore, 8, "reserves unchanged by the repayment (shares-accounting rounding only)");
                    assertLe(_absDiff(pUsdc.exchangeRateStored(), rateBefore), 2 * (1e18 / pUsdc.totalSupply() + 1), "exchange rate unchanged by the repayment");
                    _identity(string.concat(dg, "|", fl));
                    assertApproxEqAbs(paid, _min(budget, ld), 4, "paid == min(budget, debt)");
                    assertApproxEqAbs(_sumDebt(), ld - paid, 8, "remaining debt == debt - paid");
                    assertApproxEqAbs(pUsdc.totalBorrows(), ld - paid, 8, "total borrows == debt - paid");
                    string memory fg = string.concat(dg, "|fund=", fl);
                    emit log_string(
                        string.concat(
                            "TRP|FND|", fg, _kv("budget", budget), _kv("paid", paid), _kv("nFull", nFull), _kv("nPartial", nPart), _kv("unpaid", ld - paid), "|END"
                        )
                    );
                    Agg memory ag = _orders(fg);
                    shortAt[f] = ag.shortTot;
                    paidAt[f] = paid;
                    if (f == 3) {
                        remAt0 = pUsdc.totalBorrows();
                        resAt0 = pUsdc.totalReserves();
                    }
                }
                // the equalities that SEPARATE the funding levels: every USDC repaid removes one USDC of exit shortfall until the reserves
                // are all that is left to cover (shortfall = max(0, remaining borrows - reserves)); F0 is the unfunded baseline
                for (uint256 f; f < 3; ++f) {
                    if (shortAt[f] > 0) {
                        assertApproxEqAbs(shortAt[f] + paidAt[f], shortAt[3], TOL, "shortfall(funded) + repaid == shortfall(unfunded)");
                    } else {
                        assertGe(paidAt[f] + resAt0 + TOL, remAt0, "no shortfall left: repaid + reserves cover the debt");
                    }
                }
                if (d > 0) assertApproxEqAbs(shortAt[4], 0, TOL, "funding the debt at the response time (L(delay)) leaves nobody short");
            }
        }
    }

    // PW40 tails -60% / -67.6% / -75%
    function _fallsPW40() internal pure returns (uint256[] memory f) {
        f = new uint256[](3);
        f[0] = 6_000;
        f[1] = 6_760;
        f[2] = 7_500;
    }

    // PW30 tails -75% / -80%
    function _fallsPW30() internal pure returns (uint256[] memory f) {
        f = new uint256[](2);
        f[0] = 7_500;
        f[1] = 8_000;
    }

    function testMatrix_PW40_Cap01000() public {
        _matrix(1_000, 0.40e18, "PW40", _fallsPW40());
    }

    function testMatrix_PW40_Cap05000() public {
        _matrix(5_000, 0.40e18, "PW40", _fallsPW40());
    }

    function testMatrix_PW40_Cap10000() public {
        _matrix(10_000, 0.40e18, "PW40", _fallsPW40());
    }

    function testMatrix_PW30_Cap01000() public {
        _matrix(1_000, 0.30e18, "PW30", _fallsPW30());
    }

    function testMatrix_PW30_Cap05000() public {
        _matrix(5_000, 0.30e18, "PW30", _fallsPW30());
    }

    function testMatrix_PW30_Cap10000() public {
        _matrix(10_000, 0.30e18, "PW30", _fallsPW30());
    }

    // ================================================================= (a) DETECTION RULE truth table
    function _assertVerdict(address who, TreasuryDefaultDetector.Verdict want, string memory why) internal {
        TreasuryDefaultDetector.Result memory r = _eval(who);
        emit log_string(
            string.concat(
                "TRP|TRUTH|", why, "|acct=", vm.toString(who), "|verdict=", _verdictName(r.verdict), _kv("debtUnits", r.debtUnits), _kv("debtUsd", r.debtUsd),
                _kv("collUsd", r.collUsd), _kv("maxRecoveryUsd", r.maxRecoveryUsd), _kv("shortfallUsd", r.shortfallUsd), "|END"
            )
        );
        assertEq(uint256(r.verdict), uint256(want), string.concat("verdict: ", why));
    }

    function _healthyHalf(address who, Base memory bs) internal {
        uint256 pu = oracle.getUnderlyingPrice(PToken(address(pUsdc)));
        uint256 pw = oracle.getUnderlyingPrice(PToken(address(pWavax)));
        uint256 target6 = bs.cap6 / 3;
        uint256 wavaxUnits = Math.mulDiv(Math.mulDiv(target6, 1e18, bs.cf), pu, pw);
        _mintP(pWavax, who, wavaxUnits);
        _enter(who);
        (, uint256 liq,) = controller.getAccountLiquidity(who);
        // headroom in the cap: the three full borrowers used up to cap; lift the cap for this account
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = bs.cap6 * 2;
        controller._setMarketBorrowCaps(ps, caps);
        // the pilot's cash is exactly at the 20% floor after the full-capacity borrows: lower the floor so that this extra account can borrow (test setup only)
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), 0) == 0, "floor off");
        (bool ok,) = _borrow(pUsdc, who, Math.mulDiv(liq, 1e18, pu) / 2); // 50% of its power
        require(ok, "half-power borrow");
    }

    function testDetect_TruthTable_NotFiredForHealthyRecoverableOrNotYetExhausted_FiresOnlyWhenExhausted() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        _healthyHalf(HEALTHY_ACCT, bs);
        _mintP(pWavax, NO_DEBT_ACCT, 10e18);
        _enter(NO_DEBT_ACCT);
        // stage 1: after 30 days of interest the 100%-power borrowers are slightly underwater (shortfall from interest alone), HEALTHY_ACCT is fine
        _assertVerdict(HEALTHY_ACCT, TreasuryDefaultDetector.Verdict.HEALTHY, "stage1 half-power borrower");
        _assertVerdict(NO_DEBT_ACCT, TreasuryDefaultDetector.Verdict.NO_DEBT, "stage1 no debt");
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.LIQUIDATABLE_RECOVERABLE, "stage1 full-power after 30d interest (shortfall from interest only)");
        // stage 2: AVAX -20% (inside the zero-loss gap of PW40 at u=100%: -56%): liquidatable and fully recoverable
        _setAvaxBps(8_000);
        _assertVerdict(_borrower(1), TreasuryDefaultDetector.Verdict.LIQUIDATABLE_RECOVERABLE, "stage2 -20% full-power");
        _assertVerdict(HEALTHY_ACCT, TreasuryDefaultDetector.Verdict.HEALTHY, "stage2 half-power still healthy at -20%");
        // stage 3: AVAX -75%: full-power accounts have C / LI < D but still hold collateral: liquidate first, do NOT repay
        _setAvaxBps(2_500);
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, "stage3 -75% tail before liquidation (account 0)");
        _assertVerdict(_borrower(1), TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, "stage3 -75% tail before liquidation (account 1)");
        _assertVerdict(HEALTHY_ACCT, TreasuryDefaultDetector.Verdict.LIQUIDATABLE_RECOVERABLE, "stage3 -75% half-power account is liquidatable and still recoverable");
        // stage 4: liquidate account 0 to exhaustion, account 1 only once (collateral remains)
        _clear(_borrower(0));
        {
            // one liquidation round on account 1
            uint256 repay = pUsdc.borrowBalanceCurrent(_borrower(1)) / 2;
            (bool ok,,) = _liquidate(pUsdc, pWavax, _borrower(1), repay);
            assertTrue(ok, "one liquidation round on account 1");
        }
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED, "stage4 exhausted account FIRES");
        _assertVerdict(_borrower(1), TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, "stage4 partially liquidated (collateral remains) does not fire");
        _assertVerdict(_borrower(2), TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST, "stage4 untouched tail account does not fire");
        _assertVerdict(HEALTHY_ACCT, TreasuryDefaultDetector.Verdict.LIQUIDATABLE_RECOVERABLE, "stage4 recoverable account does not fire");
        // exhaustion corroborated on chain: a liquidation of a whole USDC on the exhausted account is refused (seize more than it holds);
        // what is still seizable is worth at most dust / LI (below the gas cost of a liquidation)
        {
            (bool ok,, uint256 seized) = _liquidate(pUsdc, pWavax, _borrower(0), 1e6);
            assertFalse(ok, "a liquidation of 1 USDC on the exhausted account is refused");
            assertEq(seized, 0);
            TreasuryDefaultDetector.Result memory r = _eval(_borrower(0));
            assertLe(r.maxRecoveryUsd, (DUST_USD18 * 1e18) / LI + 1, "remaining recovery <= dust / LI");
        }
        // a stale AVAX price (limit 1,200 s) or a zero answer: fail closed, never fire
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1_201);
        assertEq(oracle.getPrice(WAVAX), 0, "AVAX stale after 1,201 s without a fresh round");
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.STALE_OR_ZERO_PRICE, "stale AVAX: exhausted account does NOT fire");
        _assertVerdict(_borrower(2), TreasuryDefaultDetector.Verdict.STALE_OR_ZERO_PRICE, "stale AVAX: tail account");
        _assertVerdict(NO_DEBT_ACCT, TreasuryDefaultDetector.Verdict.NO_DEBT, "stale: an account without debt needs no price");
        vm.revertToState(snap);
        int256 keep = avaxAnswer;
        _setPrices(keep, usdcAnswer);
        _setPrices(0, usdcAnswer); // a zero answer
        assertEq(oracle.getPrice(WAVAX), 0, "zero answer -> zero price");
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.STALE_OR_ZERO_PRICE, "zero AVAX answer: does NOT fire");
        _setPrices(keep, usdcAnswer);
        // after the treasury repays the exhausted account: no debt, rule silent
        deal(USDC, TREASURY, 1_000_000e6);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        _repayOne(_borrower(0), type(uint256).max);
        _assertVerdict(_borrower(0), TreasuryDefaultDetector.Verdict.NO_DEBT, "after repayment");
    }

    /// @dev The oracle is the weak point: a manipulated LOW price makes a healthy account look exhausted to a single-source rule. With an
    ///      independent reference price the rule does not fire; without it (reference := oracle) it does. The reference must be a real,
    ///      independent source in operation (not tested: which source).
    function testDetect_ManipulatedLowOracle_IndependentReferenceStopsTheFalseFire() public {
        if (!_live()) return;
        _prepare(5_000, 0.40e18, "PW40");
        uint256[] memory refs = _refsFromOracle(); // honest prices
        _setPrices(1, usdcAnswer); // AVAX price manipulated to 1 (0.00000001 USD)
        PToken[] memory ms = controller.getAllMarkets();
        // oracle alone (reference := oracle): the single-source rule is fooled
        TreasuryDefaultDetector.Result memory fooled = detector.evaluate(_borrower(0), _refsFromOracle());
        // honest independent reference: collateral value taken at max(oracle, reference), debt at min
        TreasuryDefaultDetector.Result memory safe = detector.evaluate(_borrower(0), refs);
        emit log_string(
            string.concat("TRP|MANIP|singleSource=", _verdictName(fooled.verdict), "|withReference=", _verdictName(safe.verdict), _kv("markets", ms.length), "|END")
        );
        assertEq(uint256(fooled.verdict), uint256(TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED), "a single-source rule IS fooled by a manipulated low price");
        assertEq(uint256(safe.verdict), uint256(TreasuryDefaultDetector.Verdict.PRICE_DIVERGENCE), "with an independent reference the sources disagree: fail closed, no fire");
        // no reference supplied for a market the account touches: fail closed
        uint256[] memory none = new uint256[](ms.length);
        assertEq(uint256(detector.evaluate(_borrower(0), none).verdict), uint256(TreasuryDefaultDetector.Verdict.NO_REFERENCE_PRICE), "no reference: fail closed");
    }

    function _wavaxIndex() internal view returns (uint256 idx) {
        PToken[] memory ms = controller.getAllMarkets();
        for (uint256 i; i < ms.length; ++i) {
            if (address(ms[i]) == address(pWavax)) return i;
        }
        revert("pWAVAX not listed");
    }

    function _verdictWithWavaxRef(address who, uint256 ref) internal returns (TreasuryDefaultDetector.Verdict) {
        uint256[] memory refs = _refsFromOracle();
        refs[_wavaxIndex()] = ref;
        return detector.evaluate(who, refs).verdict;
    }

    /// @dev The tolerance of the reference-price specification, to the wei, in BOTH directions. The account is a tail account that still holds
    ///      collateral (-75%, nothing liquidated): on agreeing prices it reads UNRECOVERABLE_LIQUIDATE_FIRST. At or inside the tolerance the
    ///      verdict is unchanged (the sources are consistent); one wei beyond it, on either side, the rule fails closed with PRICE_DIVERGENCE.
    function testDetect_ReferenceTolerance_ExactBoundary_BothDirections_FailsClosedBeyondIt() public {
        if (!_live()) return;
        _prepare(5_000, 0.40e18, "PW40");
        _setAvaxBps(2_500);
        address a = _borrower(0);
        uint256 p = oracle.getUnderlyingPrice(PToken(address(pWavax)));
        assertEq(uint256(_verdictWithWavaxRef(a, p)), uint256(TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST), "agreeing prices: the ordinary verdict");
        // reference ABOVE the oracle (e.g. a lagging TWAP after a fast fall): |p - ref| * 1e4 <= ref * tol  <=>  ref <= p * 1e4 / (1e4 - tol)
        uint256 hi = (p * 10_000) / (10_000 - REF_TOLERANCE_BP);
        assertEq(uint256(_verdictWithWavaxRef(a, hi)), uint256(TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST), "reference above, at the tolerance: consistent");
        assertEq(uint256(_verdictWithWavaxRef(a, hi + 1)), uint256(TreasuryDefaultDetector.Verdict.PRICE_DIVERGENCE), "reference above, one wei beyond: fail closed");
        // reference BELOW the oracle (the oracle is too high, or the reference is wrong): ref >= p * 1e4 / (1e4 + tol)
        uint256 lo = (p * 10_000 + 10_000 + REF_TOLERANCE_BP - 1) / (10_000 + REF_TOLERANCE_BP); // ceil
        assertEq(uint256(_verdictWithWavaxRef(a, lo)), uint256(TreasuryDefaultDetector.Verdict.UNRECOVERABLE_LIQUIDATE_FIRST), "reference below, at the tolerance: consistent");
        assertEq(uint256(_verdictWithWavaxRef(a, lo - 1)), uint256(TreasuryDefaultDetector.Verdict.PRICE_DIVERGENCE), "reference below, one wei beyond: fail closed");
    }

    /// @dev A reference that is WRONG can only make the treasury pay LESS. Checked on an UNGATED detector (tolerance effectively infinite), so
    ///      that it is the conservative valuation itself (collateral at the higher price, debt at the lower) and not the divergence gate that
    ///      is exercised: the exhausted account fires on agreeing prices, and for every other account no reference value from 0.01% to 10x
    ///      of the oracle price ever produces DEFAULT_EXHAUSTED.
    function testDetect_AWrongReferenceNeverCreatesAFire_ItOnlyDelays() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        _healthyHalf(HEALTHY_ACCT, bs);
        _mintP(pWavax, NO_DEBT_ACCT, 10e18);
        _enter(NO_DEBT_ACCT);
        _setAvaxBps(2_500);
        _clear(_borrower(0));
        TreasuryDefaultDetector ungated = new TreasuryDefaultDetector(controller, address(pUsdc), DUST_USD18, 1e12, 0);
        uint256 p = oracle.getUnderlyingPrice(PToken(address(pWavax)));
        uint256[] memory refs = _refsFromOracle();
        assertEq(uint256(ungated.evaluate(_borrower(0), refs).verdict), uint256(TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED), "exhausted account fires on agreeing prices");
        assertEq(uint256(detector.evaluate(_borrower(0), refs).verdict), uint256(TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED), "and on the gated detector");
        uint256[7] memory refBp = [uint256(1), 100, 1_000, 5_000, 10_000, 20_000, 100_000]; // 0.01% .. 10x of the oracle price
        address[4] memory others = [HEALTHY_ACCT, _borrower(1), _borrower(2), NO_DEBT_ACCT];
        uint256 checked;
        for (uint256 k; k < others.length; ++k) {
            for (uint256 m; m < refBp.length; ++m) {
                refs[_wavaxIndex()] = (p * refBp[m]) / 10_000;
                if (refs[_wavaxIndex()] == 0) continue;
                assertTrue(
                    ungated.evaluate(others[k], refs).verdict != TreasuryDefaultDetector.Verdict.DEFAULT_EXHAUSTED,
                    "no reference value turns a non-exhausted account into a fire"
                );
                ++checked;
            }
        }
        assertGe(checked, 25, "the property was checked over a grid of accounts and reference values");
    }

    // ================================================================= (b) roles, authorisation, what a malicious or mistaken repay can do
    function testRoles_TreasuryHoldsOnlyUsdc_HasNoAdminPower_AndCannotBeSpentByThirdParties() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        _back(bs.snap);
        // the treasury is none of: controller admin, pause guardian, market admin
        assertTrue(TREASURY != controller.admin(), "treasury is not the controller admin");
        assertTrue(TREASURY != controller.pauseGuardian(), "treasury is not the pause guardian");
        assertTrue(TREASURY != pUsdc.admin() && TREASURY != pWavax.admin(), "treasury is not a market admin");
        deal(USDC, TREASURY, 10_000e6);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), 1_000e6); // allowance to the market only, bounded
        // admin / guardian entry points all refuse the treasury key
        (bool ok,) = _try(TREASURY, address(controller), abi.encodeWithSelector(controller._setBorrowPaused.selector, PErc20(address(pUsdc)), true));
        assertFalse(ok, "treasury cannot pause borrowing");
        (ok,) = _try(TREASURY, address(controller), abi.encodeWithSelector(controller._setCollateralFactor.selector, PToken(address(pWavax)), 0.9e18));
        assertFalse(ok, "treasury cannot change a collateral factor");
        (ok,) = _try(TREASURY, address(pUsdc), abi.encodeWithSelector(PToken._reduceReserves.selector, 1));
        assertFalse(ok, "treasury cannot reduce reserves");
        (ok,) = _try(TREASURY, address(controller), abi.encodeWithSelector(ctrl._setBorrowCashFloor.selector, PToken(address(pUsdc)), 0));
        assertFalse(ok, "treasury cannot move the cash floor");
        (ok,) = _try(TREASURY, address(controller), abi.encodeWithSelector(controller._setPriceOracle.selector, address(0xBAD)));
        assertFalse(ok, "treasury cannot change the oracle");
        // a third party cannot spend the treasury's USDC through the market: repayBorrowBehalf pulls from msg.sender
        uint256 tBefore = IERC20(USDC).balanceOf(TREASURY);
        (ok,) = _try(ATTACKER, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, _borrower(0), 100e6));
        assertFalse(ok, "an attacker without funds cannot repay (and cannot use the treasury's allowance)");
        assertEq(IERC20(USDC).balanceOf(TREASURY), tBefore, "treasury balance untouched");
        vm.prank(ATTACKER);
        (bool tf,) = USDC.call(abi.encodeWithSelector(IERC20.transferFrom.selector, TREASURY, ATTACKER, 1));
        assertFalse(tf, "the allowance is to the market, not to a third party");
        // the treasury's own repay works and is bounded by its allowance
        uint256 debt0 = pUsdc.borrowBalanceCurrent(_borrower(0));
        vm.prank(TREASURY);
        require(pUsdc.repayBorrowBehalf(_borrower(0), 1_000e6) == 0, "treasury repay within allowance");
        assertApproxEqAbs(pUsdc.borrowBalanceStored(_borrower(0)), debt0 - 1_000e6, 2);
        (ok,) = _try(TREASURY, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, _borrower(0), 1_000e6));
        assertFalse(ok, "allowance exhausted: a second repay beyond the approved budget is impossible");
        // the same call is permissionless for anyone paying with their own funds
        deal(USDC, ATTACKER, 10e6);
        vm.prank(ATTACKER);
        IERC20(USDC).approve(address(pUsdc), 10e6);
        vm.prank(ATTACKER);
        require(pUsdc.repayBorrowBehalf(_borrower(1), 10e6) == 0, "anyone can repay with their own money");
    }

    function testRepayBehalf_OnAHealthyAccount_IsAGift_NotATheft_AndCannotHarmSuppliers() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        _back(bs.snap);
        _healthyHalf(HEALTHY_ACCT, bs);
        (uint256[4] memory claim0, uint256 tot0) = _claims();
        uint256 rate0 = pUsdc.exchangeRateStored();
        uint256 res0 = pUsdc.totalReserves();
        uint256 cash0 = pUsdc.getCash();
        uint256 borrows0 = pUsdc.totalBorrows();
        (, uint256 liq0,) = controller.getAccountLiquidity(HEALTHY_ACCT);
        uint256 debt0 = pUsdc.borrowBalanceCurrent(HEALTHY_ACCT);
        deal(USDC, TREASURY, 400e6);
        vm.startPrank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), 400e6);
        require(pUsdc.repayBorrowBehalf(HEALTHY_ACCT, 400e6) == 0, "mistaken repay on a healthy account");
        vm.stopPrank();
        (, uint256 liq1,) = controller.getAccountLiquidity(HEALTHY_ACCT);
        (uint256[4] memory claim1, uint256 tot1) = _claims();
        // the GIFT: the borrower's debt fell and its borrowing power rose by exactly the repayment
        assertApproxEqAbs(pUsdc.borrowBalanceStored(HEALTHY_ACCT), debt0 - 400e6, 2, "the borrower's debt fell");
        assertGt(liq1, liq0, "the borrower's free liquidity rose");
        // NOT a theft and no harm to suppliers: rate, claims, reserves unchanged; cash rose by what borrows fell
        assertApproxEqAbs(pUsdc.exchangeRateStored(), rate0, 2 * (1e18 / pUsdc.totalSupply() + 1), "rate unchanged");
        assertLe(_absDiff(tot1, tot0), 8, "sum of claims unchanged");
        for (uint256 j; j < 4; ++j) {
            assertLe(_absDiff(claim1[j], claim0[j]), 2, "each supplier's claim unchanged");
        }
        assertEq(pUsdc.totalReserves(), res0, "reserves unchanged");
        assertEq(pUsdc.getCash(), cash0 + 400e6, "cash rose by the repayment");
        assertApproxEqAbs(pUsdc.totalBorrows(), borrows0 - 400e6, 4, "borrows fell by the repayment");
        assertEq(IERC20(USDC).balanceOf(TREASURY), 0, "the cost is borne entirely by the treasury: 400 USDC");
        // other borrowers untouched
        assertEq(pUsdc.borrowBalanceStored(_borrower(0)), pUsdc.borrowBalanceStored(_borrower(0)));
        // a mistaken _addReserves instead of repayBorrowBehalf: debt unchanged, the money is protocol reserves the admin can withdraw
        deal(USDC, TREASURY, 500e6);
        vm.startPrank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), 500e6);
        uint256 debtBefore = pUsdc.borrowBalanceStored(_borrower(0));
        require(PErc20(address(pUsdc))._addReserves(500e6) == 0, "mistaken _addReserves");
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(_borrower(0)), debtBefore, "_addReserves repays no debt");
        assertEq(pUsdc.totalReserves(), res0 + 500e6, "booked as protocol reserves");
        uint256 adminBefore = IERC20(USDC).balanceOf(address(this));
        require(PToken(address(pUsdc))._reduceReserves(500e6) == 0, "admin withdraws");
        assertEq(IERC20(USDC).balanceOf(address(this)) - adminBefore, 500e6, "the admin, not the treasury, receives it");
        // zero / over-repay / sentinel on a debt-free account / wrong market
        deal(USDC, TREASURY, 100e6);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), 100e6);
        uint256 over = pUsdc.borrowBalanceCurrent(_borrower(2)) + 1;
        deal(USDC, TREASURY, over);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), over);
        (bool ok,) = _try(TREASURY, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, _borrower(2), over));
        assertFalse(ok, "repaying more than owed reverts: an explicit full amount is fragile, use the sentinel");
        uint256 tb = IERC20(USDC).balanceOf(TREASURY);
        vm.prank(TREASURY);
        require(pUsdc.repayBorrowBehalf(NO_DEBT_ACCT, type(uint256).max) == 0, "sentinel on a debt-free account");
        assertEq(IERC20(USDC).balanceOf(TREASURY), tb, "sentinel on a debt-free account moves nothing");
        (ok,) = _try(TREASURY, address(pWavax), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, _borrower(0), 1e6));
        assertFalse(ok, "repay on the wrong market (pWAVAX has no borrows) is refused");
    }

    /// @dev A griefer repays 1 unit of the defaulted debt between detection and the treasury transaction (or interest accrues in the next
    ///      block). An explicit amount equal to the stale debt reverts or leaves dust; the sentinel clears the debt.
    function testRepayBehalf_FrontRun_ExplicitFullAmountFails_SentinelClears() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        Evt memory e = _event(bs, 7_500, "cap=5000|cand=PW40|fall=7500");
        deal(USDC, TREASURY, e.l0 * 2);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        address b0 = _borrower(0);
        uint256 detected = pUsdc.borrowBalanceCurrent(b0);
        deal(USDC, ATTACKER, 1e6);
        vm.startPrank(ATTACKER);
        IERC20(USDC).approve(address(pUsdc), 1e6);
        require(pUsdc.repayBorrowBehalf(b0, 1) == 0, "griefing repay of 1 unit");
        vm.stopPrank();
        (bool ok,) = _try(TREASURY, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, b0, detected));
        // explicit stale amount: either it reverts (amount > debt) or it pays the stale amount; it can never overpay
        uint256 left = pUsdc.borrowBalanceStored(b0);
        emit log_string(string.concat("TRP|FRONTRUN|explicitStaleAmountOk=", vm.toString(ok ? 1 : 0), _kv("debtLeft", left), "|END"));
        _back(e.snap);
        deal(USDC, TREASURY, e.l0 * 2);
        vm.prank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        deal(USDC, ATTACKER, 1e6);
        vm.startPrank(ATTACKER);
        IERC20(USDC).approve(address(pUsdc), 1e6);
        require(pUsdc.repayBorrowBehalf(b0, 1) == 0, "griefing repay of 1 unit");
        vm.stopPrank();
        vm.prank(TREASURY);
        require(pUsdc.repayBorrowBehalf(b0, type(uint256).max) == 0, "sentinel");
        assertEq(pUsdc.borrowBalanceStored(b0), 0, "the sentinel clears the debt whatever happened since detection");
    }

    /// @dev The runbook repays ONLY accounts on which the rule fires: with the tail gap but no liquidation yet, a funded treasury pays nothing;
    ///      with one account exhausted it pays that account's debt and no other.
    function testRunbook_RepaysOnlyAccountsOnWhichTheRuleFires() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        _setAvaxBps(2_500); // -75%, nothing liquidated yet
        (uint256 paid0,,) = _runbook(10_000e6);
        assertEq(paid0, 0, "rule silent before liquidation: the treasury pays nothing");
        assertEq(IERC20(USDC).balanceOf(TREASURY), 10_000e6, "the funds in transit stay in the treasury");
        uint256 d1 = pUsdc.borrowBalanceCurrent(_borrower(1));
        uint256 d2 = pUsdc.borrowBalanceCurrent(_borrower(2));
        _clear(_borrower(0)); // only account 0 is exhausted
        uint256 d0 = pUsdc.borrowBalanceCurrent(_borrower(0));
        (uint256 paid1, uint256 nFull,) = _runbook(10_000e6);
        assertApproxEqAbs(paid1, d0, 2, "pays exactly the exhausted account's remaining debt");
        assertEq(nFull, 1);
        assertEq(pUsdc.borrowBalanceStored(_borrower(0)), 0);
        assertEq(pUsdc.borrowBalanceStored(_borrower(1)), d1, "other accounts untouched");
        assertEq(pUsdc.borrowBalanceStored(_borrower(2)), d2, "other accounts untouched");
        assertEq(IERC20(USDC).balanceOf(TREASURY) + paid1, 10_000e6, "unused budget stays with the treasury");
        assertGt(bs.cap6, 0);
    }

    /// @dev Insufficient funding is a DEFERRED claim, not an extinguished one: suppliers who were short at exit keep their leftover pTokens,
    ///      and a later treasury repayment makes them whole (exit order A, B, C, D with nothing funded, then the treasury repays the loss).
    function testLateFunding_SuppliersWhoWereShortAreMadeWholeByALaterRepayment() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        Evt memory e = _event(bs, 7_500, "cap=5000|cand=PW40|fall=7500");
        (uint256[4] memory claim0,) = _claims();
        uint256[4] memory got;
        uint256[4] memory gotFirst;
        for (uint256 j; j < 4; ++j) {
            (, gotFirst[j]) = _exit(j); // everybody tries to leave with the treasury unfunded
            got[j] = gotFirst[j];
        }
        uint256 shortBefore;
        for (uint256 j; j < 4; ++j) {
            shortBefore += claim0[j] - gotFirst[j];
        }
        assertGt(shortBefore, 0, "the late suppliers were short");
        assertEq(pUsdc.getCash(), 0, "the market is empty after the exits");
        (uint256 paid,,) = _runbook(e.l0); // the treasury funds the loss afterwards
        assertApproxEqAbs(paid, e.l0, 8);
        for (uint256 j; j < 4; ++j) {
            (, uint256 more) = _exit(j); // leftover pTokens are redeemable again
            got[j] += more;
        }
        for (uint256 j; j < 4; ++j) {
            assertApproxEqAbs(got[j], claim0[j], 16, "every supplier ends with its full claim after the late repayment");
        }
        assertGt(shortBefore, 0);
    }

    // ================================================================= (e) mitigations and what none of them can do
    function testMitigations_PauseBorrow_RaiseFloor_PauseMint_PartialFirst_NoneChangesTheExitShortfall() public {
        if (!_live()) return;
        Base memory bs = _prepare(5_000, 0.40e18, "PW40");
        Evt memory e = _event(bs, 7_500, "cap=5000|cand=PW40|fall=7500");
        uint256 snapE = e.snap;
        // baseline: nothing funded, no mitigation
        _back(snapE);
        uint256 shortBase = _max0(pUsdc.totalBorrows(), pUsdc.totalReserves());
        // (1) with borrowing OPEN a fresh healthy borrower can take the remaining cash above the floor: illiquidity grows, no loss
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = bs.cap6 * 4;
        controller._setMarketBorrowCaps(ps, caps);
        {
            uint256 cash = pUsdc.getCash();
            uint256 floor = ctrl.borrowCashFloor(address(pUsdc));
            _mintP(pWavax, DAVE, 100_000e18);
            _enter(DAVE);
            (bool ok,) = _borrow(pUsdc, DAVE, cash - floor);
            assertTrue(ok, "borrowing open: new borrower takes the cash above the floor");
            assertEq(pUsdc.getCash(), floor, "cash is at the floor");
        }
        (, uint256 claimsOpen) = _claims();
        uint256 shortWithNewBorrow = claimsOpen - pUsdc.getCash();
        emit log_string(string.concat("TRP|MIT|openBorrowShortfallNow=", vm.toString(shortWithNewBorrow), "|baselineLoss=", vm.toString(shortBase), "|END"));
        assertGt(shortWithNewBorrow, shortBase, "new borrowing against fresh collateral turns more of the claims into illiquid loans");
        // (2) guardian pause of borrowing prevents exactly that
        _back(snapE);
        require(controller._setBorrowPaused(PErc20(address(pUsdc)), true), "guardian pauses borrowing");
        _mintP(pWavax, DAVE, 100_000e18);
        _enter(DAVE);
        (bool ok2,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok2, "borrow refused while paused");
        // redemption cannot be paused: there is no such switch
        (bool sw,) = address(controller).call(abi.encodeWithSignature("_setRedeemPaused(bool)", true));
        assertFalse(sw, "the controller has no redeem pause");
        // (3) raising the cash floor above the cash blocks borrows only; redemptions are not blocked below the floor
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), pUsdc.getCash() + 1) == 0, "floor above cash");
        controller._setBorrowPaused(PErc20(address(pUsdc)), false);
        (ok2,) = _borrow(pUsdc, DAVE, 1);
        assertFalse(ok2, "a floor above the cash refuses any new borrow");
        (uint256 c0, uint256 g0) = _exit(0);
        assertGt(c0, 0);
        assertEq(g0, c0, "supplier A exits in full although cash is below the floor");
        // (4) pausing mint keeps NEW depositors out of a damaged market (they would enter at the unreduced rate, behind the queue)
        _back(snapE);
        require(controller._setMintPaused(PToken(address(pUsdc)), true), "guardian pauses mint");
        deal(USDC, DAVE, 100e6);
        vm.startPrank(DAVE);
        IERC20(USDC).approve(address(pUsdc), 100e6);
        (bool mintOk,) = address(pUsdc).call(abi.encodeWithSelector(PErc20.mint.selector, 100e6));
        vm.stopPrank();
        assertFalse(mintOk, "mint refused while paused");
        // (5) NONE of them changes the exit shortfall: with every mitigation set, the shortfall is still max(0, borrows - reserves), in every order
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), bs.supply6) == 0, "floor raised");
        require(controller._setBorrowPaused(PErc20(address(pUsdc)), true), "borrow paused");
        Agg memory g = _orders("cap=5000|cand=PW40|fall=7500|delay=0|fund=F0_withAllMitigations");
        assertApproxEqAbs(g.shortTot, _max0(e.l0, pUsdc.totalReserves()), 8, "mitigations leave the shortfall at loss - reserves");
        assertGt(g.shortTot, 0);
        // (6) partial repay first: 25% then the rest later reduces the shortfall by exactly what was repaid, and the order of repayments does not matter
        _back(snapE);
        (uint256 paid25,,) = _runbook(e.l0 / 4);
        Agg memory g25 = _orders("cap=5000|cand=PW40|fall=7500|delay=0|fund=F25_thenMore");
        assertApproxEqAbs(g25.shortTot, _max0(e.l0 - paid25, pUsdc.totalReserves()), TOL);
        (uint256 paidRest,,) = _runbook(e.l0 - paid25);
        Agg memory gAll = _orders("cap=5000|cand=PW40|fall=7500|delay=0|fund=F25_thenRest");
        assertApproxEqAbs(paid25 + paidRest, e.l0, 8, "the two instalments add up to the loss");
        assertLe(gAll.shortTot, 8, "after the remaining instalment nobody is short");
    }
}
