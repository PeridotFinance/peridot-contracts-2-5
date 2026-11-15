// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import "./helpers/AvalancheWavaxUsdcRoutes.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice PART B of the cash-only liquidation-cycle study (product: cash-only lending pilot PW30 / PW40, markets pUSDC and pWAVAX).
 *
 * One liquidation cycle, executed for real on the pinned fork (block 99,200,000):
 *   price gap -> funded repayment (the operator spends USDC it holds) -> seizure of pWAVAX -> redemption pWAVAX -> WAVAX (market cash)
 *   -> conversion WAVAX -> USDC through a REAL router with a stated, revert-protected min-out limit -> the NEXT liquidation is funded from
 *   whatever USDC the operator then holds.
 *
 * What is real: lending markets (the cash-only fixture), the route (real pool + real router, no mock), balances. What is not: the only
 * USDC the operators ever receive from outside the system is their initial inventory (`deal`, the "funding" being measured); afterwards the
 * inventory moves only by repayments (out) and swap proceeds (in). The base class helpers `_liquidate` / `_repay` call `deal` before each
 * call and are NOT used here.
 *
 * PRICE GAP WITHOUT DISTORTING THE CONVERSION: the feed is mocked UP while the borrowers borrow at 100% of their borrowing power, then the
 * mock is cleared: liquidation, seizure valuation and conversion all happen at the real pinned Chainlink price and the real pool state.
 * (A gap of g% means: price at borrowing = pin / (1 - g).) Research sizes only: the caps 1,000 / 5,000 / 10,000 USDC are NOT approved caps.
 * Concurrent borrowers SPLIT the cap (sum of debts = cap). Gas: measured by gasleft() around each call + 21,000 intrinsic per transaction,
 * priced at 2.5 gwei and the Chainlink AVAX price of the pin.
 */
contract AvalancheCashOnlyLiquidationCycleForkTest is AvalancheCashOnlyBase, AvalancheWavaxUsdcRoutes {
    PeridottrollerAvalanche internal ctrl;

    address internal constant OP_A = address(0x0A0A0A);
    address internal constant OP_B = address(0x0B0B0B);
    address internal constant WHALE = address(0xDEAD0002);
    uint256 internal constant NONE = 99;
    uint256 internal constant GAS_PRICE_WEI = 2.5 gwei;
    uint256 internal constant UNLIMITED = 1e15; // USDC units: USD 1 billion, used only to MEASURE the requirement
    uint256 internal constant MIN_REPAY = 1e6; // an operator with less than 1 USDC does not liquidate

    // research routes (ranked in the doc by part A)
    uint256 internal PRIMARY = R_UNI3_500;
    uint256 internal SECOND = R_PHARAOH_TS10;

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return;
        ctrl = PeridottrollerAvalanche(address(controller));
        // pilot configuration, as in AvalancheCashOnlyPilotConfigFork.t.sol (proposal values, not approved)
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.40e18) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0) == 0, "cf u off");
        controller._setBorrowPaused(PErc20(address(pUsdc)), false); // WAVAX borrowing stays paused
        _setCap(320_000e6);
        require(ctrl._setBorrowCashFloor(PToken(address(pUsdc)), 80_000e6) == 0, "floor"); // 20% of supply
        assertEq(PToken(address(pUsdc)).protocolSeizeShareMantissa(), 2.8e16, "protocol seize share");
        assertEq(controller.closeFactorMantissa(), 0.5e18, "close factor");
        assertEq(controller.liquidationIncentiveMantissa(), 1.08e18, "incentive");
    }

    function _setCap(uint256 units) internal {
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = units;
        controller._setMarketBorrowCaps(ps, caps);
    }

    // ================================================================= configuration of one run
    struct Cfg {
        string tag;
        uint256 cfBps; // 3000 (PW30) or 4000 (PW40)
        uint256 capUsd; // total USDC debt, research size
        uint256 n; // borrowers (the cap is split evenly)
        uint256 gapBp; // fall of the AVAX price after borrowing
        uint256 route; // primary conversion route
        uint256 fallbackRoute; // NONE or a second route tried when the primary is blocked
        uint256 limitBp; // min-out: oracle value x (1 - limitBp/1e4)
        bool recycle; // redeem and convert after each liquidation
        uint256 invA; // USDC inventory of operator A
        uint256 invB;
        bool aUp;
        bool bUp;
        bool interleave; // one round per borrower in turn, operators alternating; else each borrower is finished before the next
        uint256 adverseBp; // before the first conversion the primary route's pool is pushed this far below the oracle price (real trades)
        uint256 stage2Bp; // after the run: oracle price = pin x (1 - stage2Bp) to measure bad debt of accounts left in shortfall (0 = off)
        bool logRounds;
    }

    struct Res {
        uint256 debt0; // sum of initial debts (USDC units)
        uint256 repaid;
        uint256 proceeds; // USDC received from conversions
        uint256 gasUnits; // total gas incl. 21,000 intrinsic per transaction
        uint256 gasCostUsdc;
        uint256 rounds;
        uint256 unfunded; // steps where the operator inventory was below the wanted repayment
        uint256 blocked; // conversions blocked by the min-out limit (or failed)
        uint256 swaps;
        uint256[2] peakNeed; // required initial inventory per operator WITH recycling = max over its liquidations of (cum repaid - cum proceeds before)
        uint256 shortfallAccts; // accounts still in shortfall at the end
        uint256 debtLeft;
        uint256 bad6; // bad debt at the gapped price
        uint256 shortfallAcctsS2;
        uint256 bad6S2; // bad debt at the stage-2 price
        uint256 wavaxHeld; // unconverted WAVAX (redeemed) held by the operators
        uint256 pHeldValue; // unredeemed pWAVAX claims, value in USDC at the oracle
        uint256 invEndA;
        uint256 invEndB;
        uint256 minRatioBp; // worst conversion output / oracle value
        uint256 maxRatioBp;
        uint256 cashBefore;
        uint256 cashAfter;
    }

    function _opAddr(uint256 k) internal pure returns (address) {
        return k == 0 ? OP_A : OP_B;
    }

    function _borrowerAddr(uint256 i) internal pure returns (address) {
        return address(uint160(0xBB000 + i));
    }

    function _wavaxToUsdcOracle(uint256 w) internal view returns (uint256) {
        return Math.mulDiv(w, uint256(avaxAnswer), uint256(usdcAnswer) * 1e12);
    }

    function _gasUsdc(uint256 g) internal view returns (uint256) {
        return Math.mulDiv(g * GAS_PRICE_WEI, uint256(realAvaxAnswer), 1e20);
    }

    // ================================================================= borrowers at 100% of borrowing power
    function _openBorrowers(Cfg memory c) internal returns (uint256 debt0) {
        uint256 capUnits = c.capUsd * 1e6;
        require(controller._setCollateralFactor(PToken(address(pWavax)), (c.cfBps * 1e18) / 10_000) == 0, "cf");
        _setCap(capUnits + 1_000); // the borrow cap is a strict bound: leave 0.001 USDC for rounding at 100% of capacity
        uint256 hi = (uint256(realAvaxAnswer) * 10_000) / (10_000 - c.gapBp);
        _setPrices(int256(hi), usdcAnswer);
        uint256 each = capUnits / c.n;
        for (uint256 i; i < c.n; ++i) {
            address b = _borrowerAddr(i);
            // collateral value needed for `each` of capacity: each / CF, in WAVAX at the (raised) price
            uint256 coll = Math.mulDiv(each * 1e20, 10_000, hi * c.cfBps);
            _mintP(pWavax, b, coll);
            _enter(b);
            (, uint256 liq,) = controller.getAccountLiquidity(b);
            uint256 max6 = liq / 1e12;
            (bool ok,) = _borrow(pUsdc, b, max6);
            if (!ok) {
                emit log_string(string.concat("BORROW|", c.tag, "|exact 100% capacity refused, retry max-1 (", vm.toString(max6), ")"));
                (ok,) = _borrow(pUsdc, b, max6 - 1);
            }
            require(ok, "borrow at 100% of borrowing power failed");
            debt0 += pUsdc.borrowBalanceStored(b);
            (, , uint256 sf) = controller.getAccountLiquidity(b);
            assertEq(sf, 0, "healthy right after borrowing");
        }
        // restore the real pinned price: the conversion and the liquidation happen at real state
        vm.clearMockedCalls();
        avaxAnswer = realAvaxAnswer;
        require(oracle.getPrice(WAVAX) > 0, "real AVAX feed fresh");
    }

    // ================================================================= adverse move of the primary pool (real trades)
    function _pushPoolDown(uint256 routeId, uint256 bp) internal returns (uint256 usdTraded) {
        uint256 target = (uint256(realAvaxAnswer) * (10_000 - bp)) / 10_000;
        uint256 chunk = Math.mulDiv(20_000e6, 1e12 * 1e8, uint256(realAvaxAnswer));
        for (uint256 k; k < 80; ++k) {
            if (_spot8(routeId) <= target) break;
            deal(WAVAX, WHALE, chunk);
            SwapRes memory s = _swapRoute(routeId, WHALE, chunk, 0);
            if (!s.ok) break;
            usdTraded += 20_000;
        }
    }

    // ================================================================= one liquidation step (+ redemption + conversion)
    struct Cum {
        uint256[2] repaid;
        uint256[2] proceeds;
    }

    struct Out {
        uint256 repay;
        uint256 seizedUsd6;
        uint256 redeemed;
        uint256 swapIn;
        uint256 swapOut;
        uint256 ratioBp;
        bool blocked;
        uint256 gasTx;
    }

    function _pickOp(Cfg memory c, uint256 turn) internal pure returns (uint256 k, bool any) {
        if (c.aUp && c.bUp) return (c.interleave ? turn % 2 : 0, true);
        if (c.aUp) return (0, true);
        if (c.bUp) return (1, true);
        return (0, false);
    }

    /// @dev Wanted repayment: the close factor of the current debt, capped by what the collateral can pay for, then by the operator's inventory.
    function _plan(Res memory r, uint256 k, uint256 i) internal returns (uint256 repay) {
        address b = _borrowerAddr(i);
        uint256 debt = pUsdc.borrowBalanceCurrent(b);
        (, , uint256 sf) = controller.getAccountLiquidity(b);
        if (debt == 0 || sf == 0) return 0;
        repay = (debt * controller.closeFactorMantissa()) / 1e18;
        uint256 coll6 = _wavaxToUsdcOracle(Math.mulDiv(pWavax.balanceOf(b), pWavax.exchangeRateStored(), 1e18));
        uint256 maxBySeize = (coll6 * 9_240) / 10_000;
        if (repay > maxBySeize) repay = maxBySeize;
        if (repay == 0) return 0;
        uint256 inv = IERC20(USDC).balanceOf(_opAddr(k));
        if (inv < repay) {
            ++r.unfunded;
            if (inv < MIN_REPAY) return 0; // cannot fund anything: the account stays in shortfall
            repay = inv; // partial liquidation with all the operator holds (allowed: <= close factor)
        }
    }

    function _doLiquidate(Cfg memory c, uint256 k, uint256 i, Out memory o) internal returns (bool) {
        address op = _opAddr(k);
        uint256 pBefore = pWavax.balanceOf(op);
        vm.prank(op);
        IERC20(USDC).approve(address(pUsdc), o.repay);
        vm.prank(op);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            address(pUsdc).call(abi.encodeWithSelector(PErc20.liquidateBorrow.selector, _borrowerAddr(i), o.repay, address(pWavax)));
        o.gasTx += (g0 - gasleft()) + 21_000;
        if (!ok || (ret.length == 32 && abi.decode(ret, (uint256)) != 0)) {
            emit log_string(string.concat("LIQFAIL|", c.tag, "|borrower ", vm.toString(i), "|", vm.toString(ret)));
            return false;
        }
        uint256 seizedP = pWavax.balanceOf(op) - pBefore;
        // seize identity: liquidator's share = repay x LI x (1 - protocol share) at oracle prices (USDC/USD feed included)
        uint256 expectedUsd6 = Math.mulDiv(o.repay, 1.08e18 * (1e18 - 2.8e16), 1e36);
        expectedUsd6 = Math.mulDiv(expectedUsd6, uint256(usdcAnswer), 1e8);
        o.seizedUsd6 = Math.mulDiv(Math.mulDiv(seizedP, pWavax.exchangeRateStored(), 1e18), uint256(avaxAnswer), 1e8 * 1e12);
        assertApproxEqAbs(o.seizedUsd6, expectedUsd6, expectedUsd6 / 100_000 + 3, "seize identity: repay x 1.08 x (1 - 2.8%)");
        return true;
    }

    function _doRedeem(uint256 k, Out memory o) internal {
        address op = _opAddr(k);
        uint256 pAll = pWavax.balanceOf(op);
        uint256 expectedW = Math.mulDiv(pAll, pWavax.exchangeRateStored(), 1e18);
        uint256 w0 = IERC20(WAVAX).balanceOf(op);
        vm.prank(op);
        uint256 g0 = gasleft();
        (bool rok, bytes memory rret) = address(pWavax).call(abi.encodeWithSelector(PErc20.redeem.selector, pAll));
        o.gasTx += (g0 - gasleft()) + 21_000;
        require(rok && (rret.length != 32 || abi.decode(rret, (uint256)) == 0), "redeem failed");
        o.redeemed = IERC20(WAVAX).balanceOf(op) - w0;
        assertEq(o.redeemed, expectedW, "redemption identity: pTokens x exchange rate");
    }

    function _doConvert(Cfg memory c, Res memory r, Cum memory cum, uint256 k, Out memory o, bool firstConversion) internal {
        address op = _opAddr(k);
        o.swapIn = IERC20(WAVAX).balanceOf(op);
        uint256 oracleVal = _wavaxToUsdcOracle(o.swapIn);
        uint256 minOut = (oracleVal * (10_000 - c.limitBp)) / 10_000;
        if (firstConversion && c.adverseBp > 0) {
            uint256 traded = _pushPoolDown(c.route, c.adverseBp);
            emit log_string(string.concat("ADVERSE|", c.tag, "|pool pushed to spot8 ", vm.toString(_spot8(c.route)), " by selling USD ", vm.toString(traded), " of WAVAX"));
        }
        SwapRes memory s = _swapRoute(c.route, op, o.swapIn, minOut);
        o.gasTx += s.gasUsed + 21_000;
        if ((!s.ok || s.out < minOut) && c.fallbackRoute != NONE) {
            s = _swapRoute(c.fallbackRoute, op, o.swapIn, minOut);
            o.gasTx += s.gasUsed + 21_000;
        }
        if (s.ok) {
            require(s.out >= minOut, "min-out must hold when the router succeeds");
            o.swapOut = s.out;
            ++r.swaps;
            o.ratioBp = (o.swapOut * 10_000) / oracleVal;
            if (o.ratioBp < r.minRatioBp) r.minRatioBp = o.ratioBp;
            if (o.ratioBp > r.maxRatioBp) r.maxRatioBp = o.ratioBp;
            r.proceeds += o.swapOut;
            cum.proceeds[k] += o.swapOut;
        } else {
            o.blocked = true;
            ++r.blocked;
            // a blocked conversion leaves the input untouched (revert protection)
            assertEq(IERC20(WAVAX).balanceOf(op), o.swapIn, "blocked swap leaves the WAVAX with the operator");
        }
    }

    function _step(Cfg memory c, Res memory r, Cum memory cum, uint256 k, uint256 i, uint256 roundNo, bool firstConversion)
        internal
        returns (bool)
    {
        Out memory o;
        o.repay = _plan(r, k, i);
        if (o.repay == 0) return false;
        if (!_doLiquidate(c, k, i, o)) return false;
        ++r.rounds;
        r.repaid += o.repay;
        cum.repaid[k] += o.repay;
        {
            uint256 need = cum.repaid[k] - cum.proceeds[k];
            if (need > r.peakNeed[k]) r.peakNeed[k] = need;
        }
        if (c.recycle) {
            _doRedeem(k, o);
            _doConvert(c, r, cum, k, o, firstConversion);
        }
        r.gasUnits += o.gasTx;
        uint256 gasUsdc = _gasUsdc(o.gasTx);
        r.gasCostUsdc += gasUsdc;
        if (c.logRounds) _logRound(c, k, i, roundNo, o, gasUsdc);
        return true;
    }

    function _logRound(Cfg memory c, uint256 k, uint256 i, uint256 roundNo, Out memory o, uint256 gasUsdc) internal {
        int256 net = int256(o.swapOut) - int256(o.repay) - int256(gasUsdc);
        string memory l1 = string.concat(
            "ROUND|", c.tag, "|r", vm.toString(roundNo), "|op", k == 0 ? "A" : "B", "|b", vm.toString(i), "|repay=", vm.toString(o.repay)
        );
        string memory l2 = string.concat(
            "|seizedValueUsdc=", vm.toString(o.seizedUsd6), "|redeemedWavax=", vm.toString(o.redeemed), "|swapInWavax=", vm.toString(o.swapIn),
            "|swapOutUsdc=", vm.toString(o.swapOut), "|outVsOracleBp=", vm.toString(o.ratioBp), o.blocked ? "|BLOCKED" : ""
        );
        string memory l3 = string.concat(
            "|gas=", vm.toString(o.gasTx), "|gasUsdc=", vm.toString(gasUsdc), "|netUsdc=", vm.toString(net),
            "|netBpOfRepay=", vm.toString(net * 10_000 / int256(o.repay))
        );
        string memory l4 = string.concat("|invA=", vm.toString(IERC20(USDC).balanceOf(OP_A)), "|invB=", vm.toString(IERC20(USDC).balanceOf(OP_B)));
        emit log_string(string.concat(l1, l2, l3, l4));
    }

    // ================================================================= one full run
    function _run(Cfg memory c) internal returns (Res memory r) {
        r.minRatioBp = type(uint256).max;
        r.debt0 = _openBorrowers(c);
        r.cashBefore = pUsdc.getCash();
        if (c.invA > 0) deal(USDC, OP_A, c.invA);
        if (c.invB > 0) deal(USDC, OP_B, c.invB);
        uint256 invA0 = IERC20(USDC).balanceOf(OP_A);
        uint256 invB0 = IERC20(USDC).balanceOf(OP_B);
        Cum memory cum;
        uint256 turn;
        uint256 roundNo;
        bool firstConv = true;
        for (uint256 pass; pass < 40; ++pass) {
            bool progress;
            for (uint256 i; i < c.n; ++i) {
                for (uint256 inner; inner < (c.interleave ? 1 : 12); ++inner) {
                    (uint256 k, bool any) = _pickOp(c, turn);
                    if (!any) break;
                    bool did = _step(c, r, cum, k, i, ++roundNo, firstConv);
                    if (!did) break;
                    ++turn;
                    if (c.recycle) firstConv = false;
                    progress = true;
                }
            }
            if (!progress) break;
        }
        r.invEndA = IERC20(USDC).balanceOf(OP_A);
        r.invEndB = IERC20(USDC).balanceOf(OP_B);
        r.cashAfter = pUsdc.getCash();
        // ---- accounting identities
        assertEq(r.cashAfter, r.cashBefore + r.repaid, "market cash grew by exactly the repayments");
        assertEq(invA0 + invB0 + r.proceeds, r.invEndA + r.invEndB + r.repaid, "operator USDC conservation: start + proceeds = end + repaid");
        for (uint256 k2; k2 < 2; ++k2) {
            r.wavaxHeld += IERC20(WAVAX).balanceOf(_opAddr(k2));
            r.pHeldValue += _wavaxToUsdcOracle(Math.mulDiv(pWavax.balanceOf(_opAddr(k2)), pWavax.exchangeRateStored(), 1e18));
        }
        _endState(c, r);
        vm.clearMockedCalls();
        avaxAnswer = realAvaxAnswer;
    }

    function _endState(Cfg memory c, Res memory r) internal {
        for (uint256 i; i < c.n; ++i) {
            address b = _borrowerAddr(i);
            uint256 debt = pUsdc.borrowBalanceCurrent(b);
            (, , uint256 sf) = controller.getAccountLiquidity(b);
            uint256 coll = _wavaxToUsdcOracle(Math.mulDiv(pWavax.balanceOf(b), pWavax.exchangeRateStored(), 1e18));
            r.debtLeft += debt;
            if (sf > 0) ++r.shortfallAccts;
            if (debt > coll) r.bad6 += debt - coll;
        }
        if (c.stage2Bp > 0) {
            _setPrices(int256((uint256(realAvaxAnswer) * (10_000 - c.stage2Bp)) / 10_000), usdcAnswer);
            for (uint256 i; i < c.n; ++i) {
                address b = _borrowerAddr(i);
                uint256 debt = pUsdc.borrowBalanceCurrent(b);
                (, , uint256 sf) = controller.getAccountLiquidity(b);
                uint256 coll = _wavaxToUsdcOracle(Math.mulDiv(pWavax.balanceOf(b), pWavax.exchangeRateStored(), 1e18));
                if (sf > 0) ++r.shortfallAcctsS2;
                if (debt > coll) r.bad6S2 += debt - coll;
            }
            vm.clearMockedCalls();
            avaxAnswer = realAvaxAnswer;
        }
    }

    /// @dev Run from a fresh snapshot of the post-setUp state; the state is reverted afterwards (the results live in memory).
    function _fresh(Cfg memory c) internal returns (Res memory r) {
        uint256 snap = vm.snapshotState();
        r = _run(c);
        vm.revertToState(snap);
        vm.clearMockedCalls();
        avaxAnswer = realAvaxAnswer;
    }

    function _cfg(string memory tag, uint256 cf, uint256 cap, uint256 n, uint256 gapBp) internal view returns (Cfg memory c) {
        c.tag = tag;
        c.cfBps = cf;
        c.capUsd = cap;
        c.n = n;
        c.gapBp = gapBp;
        c.route = PRIMARY;
        c.fallbackRoute = NONE;
        c.limitBp = 100;
        c.recycle = true;
        c.invA = UNLIMITED;
        c.aUp = true;
        c.bUp = false;
        c.logRounds = true;
    }

    function _sum(Res memory r) internal pure returns (string memory) {
        string memory p1 = string.concat(
            "debt0=", vm.toString(r.debt0), "|repaid=", vm.toString(r.repaid), "|proceeds=", vm.toString(r.proceeds), "|rounds=", vm.toString(r.rounds)
        );
        string memory p2 = string.concat(
            "|swaps=", vm.toString(r.swaps), "|blocked=", vm.toString(r.blocked), "|unfundedSteps=", vm.toString(r.unfunded),
            "|gasUnits=", vm.toString(r.gasUnits), "|gasUsdc=", vm.toString(r.gasCostUsdc)
        );
        string memory p3 = string.concat(
            "|peakNeedA=", vm.toString(r.peakNeed[0]), "|peakNeedB=", vm.toString(r.peakNeed[1]), "|acctsInShortfall=", vm.toString(r.shortfallAccts),
            "|debtLeft=", vm.toString(r.debtLeft), "|bad6=", vm.toString(r.bad6)
        );
        string memory p4 = string.concat(
            "|wavaxHeld=", vm.toString(r.wavaxHeld), "|pHeldValueUsdc=", vm.toString(r.pHeldValue), "|invEndA=", vm.toString(r.invEndA),
            "|invEndB=", vm.toString(r.invEndB)
        );
        return string.concat(p1, p2, p3, p4);
    }

    function _name(uint256 cf, uint256 cap, string memory what) internal pure returns (string memory) {
        return string.concat(cf == 3000 ? "PW30" : "PW40", "/cap", vm.toString(cap), "/", what);
    }

    // ================================================================= CASE 1 + 4: single borrower, recycling vs no recycling, funding required
    function _case1(uint256 cf, uint256 cap, uint256 gapBp) internal {
        string memory nm = _name(cf, cap, string.concat("gap", vm.toString(gapBp), "/n1"));
        Cfg memory c = _cfg(string.concat(nm, "/RECYCLE"), cf, cap, 1, gapBp);
        Res memory rec = _fresh(c);
        emit log_string(string.concat("CASE1|", nm, "|RECYCLE|", _sum(rec)));
        assertEq(rec.shortfallAccts, 0, "recycling run clears the account");
        assertEq(rec.bad6, 0, "no bad debt");
        assertEq(rec.unfunded, 0, "unlimited inventory");
        assertEq(rec.blocked, 0, "conversion not blocked at this size within the stated limit");
        // no recycling: the operator never converts
        Cfg memory n = _cfg(string.concat(nm, "/NORECYCLE"), cf, cap, 1, gapBp);
        n.recycle = false;
        Res memory nor = _fresh(n);
        emit log_string(string.concat("CASE1|", nm, "|NORECYCLE|", _sum(nor)));
        assertEq(nor.shortfallAccts, 0, "no-recycling run (unlimited inventory) clears the account");
        assertEq(nor.repaid, rec.repaid, "same liquidations either way: total repayments equal");
        // TEST the funding numbers
        // (a) WITH recycling: the measured requirement funds every step; one unit less leaves a step unfunded
        Cfg memory v = _cfg(string.concat(nm, "/RECYCLE-exact"), cf, cap, 1, gapBp);
        v.invA = rec.peakNeed[0];
        v.logRounds = false;
        Res memory vr = _fresh(v);
        assertEq(vr.unfunded, 0, "recycling: peak need funds every step");
        assertEq(vr.repaid, rec.repaid, "same repayments");
        assertEq(vr.shortfallAccts, 0, "cleared");
        v.invA = rec.peakNeed[0] - 1;
        Res memory vl = _fresh(v);
        assertGt(vl.unfunded, 0, "recycling: one unit less than the peak need leaves a step unfunded");
        // (b) WITHOUT recycling: the sum of repayments funds everything; 90% of it cannot
        Cfg memory w = _cfg(string.concat(nm, "/NORECYCLE-exact"), cf, cap, 1, gapBp);
        w.recycle = false;
        w.logRounds = false;
        w.invA = nor.repaid;
        Res memory wr = _fresh(w);
        assertEq(wr.unfunded, 0, "no recycling: sum of repayments funds every step");
        assertEq(wr.invEndA, 0, "no recycling: inventory fully spent");
        assertEq(wr.shortfallAccts, 0, "cleared");
        w.invA = (nor.repaid * 9) / 10;
        Res memory wl = _fresh(w);
        assertGt(wl.unfunded, 0, "no recycling: 90% of the sum leaves a step unfunded");
        string memory f1 = string.concat(
            "FUND|", nm, "|noRecycle=", vm.toString(nor.repaid), "|withRecycle=", vm.toString(rec.peakNeed[0]), "|difference=",
            vm.toString(nor.repaid - rec.peakNeed[0])
        );
        string memory f2 = string.concat(
            "|debt0=", vm.toString(rec.debt0), "|noRecycleOverDebtBp=", vm.toString(nor.repaid * 10_000 / rec.debt0),
            "|withRecycleOverDebtBp=", vm.toString(rec.peakNeed[0] * 10_000 / rec.debt0), "|rounds=", vm.toString(rec.rounds)
        );
        emit log_string(
            string.concat(f1, f2, "|shortage90pctNoRecycle: acctsInShortfall=", vm.toString(wl.shortfallAccts), ",debtLeft=", vm.toString(wl.debtLeft))
        );
    }

    function test_case1_single_PW30() public {
        if (address(controller) == address(0)) return;
        uint256[3] memory caps = [uint256(1_000), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) _case1(3000, caps[i], 3_500);
        _case1(3000, 5_000, 1_000);
    }

    function test_case1_single_PW40() public {
        if (address(controller) == address(0)) return;
        uint256[3] memory caps = [uint256(1_000), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) _case1(4000, caps[i], 3_500);
        _case1(4000, 5_000, 1_000);
    }

    // ================================================================= CASE 2: concurrent borrowers
    function _case2(uint256 cf, uint256 cap, uint256 n) internal {
        string memory nm = _name(cf, cap, string.concat("gap3500/n", vm.toString(n)));
        // (a) in sequence, one operator, unlimited inventory: the funding requirement
        Cfg memory a = _cfg(string.concat(nm, "/SEQ"), cf, cap, n, 3_500);
        Res memory ra = _fresh(a);
        emit log_string(string.concat("CASE2|", nm, "|SEQ-1op-recycle|", _sum(ra)));
        assertEq(ra.shortfallAccts, 0, "sequential: all accounts cleared");
        assertEq(ra.bad6, 0, "no bad debt");
        // (b) interleaved, two operators, each funded with the first round of the aggregate debt (cap / 2) and recycling
        Cfg memory b = _cfg(string.concat(nm, "/INTERLEAVED"), cf, cap, n, 3_500);
        b.interleave = true;
        b.bUp = true;
        b.invA = (cap * 1e6) / 2;
        b.invB = (cap * 1e6) / 2;
        Res memory rb = _fresh(b);
        emit log_string(string.concat("CASE2|", nm, "|INTERLEAVED-2op-recycle-inv=cap/2-each|", _sum(rb)));
        assertEq(rb.unfunded, 0, "interleaved: first-round inventory per operator suffices with recycling");
        assertEq(rb.shortfallAccts, 0, "interleaved: all accounts cleared");
        assertEq(rb.repaid, ra.repaid, "same total repayments as sequential");
        // (c) interleaved without recycling and the same inventories
        Cfg memory d = _cfg(string.concat(nm, "/INTERLEAVED-NORECYCLE"), cf, cap, n, 3_500);
        d.interleave = true;
        d.bUp = true;
        d.recycle = false;
        d.invA = (cap * 1e6) / 2;
        d.invB = (cap * 1e6) / 2;
        Res memory rd = _fresh(d);
        emit log_string(string.concat("CASE2|", nm, "|INTERLEAVED-2op-NORECYCLE-inv=cap/2-each|", _sum(rd)));
        assertLe(rd.repaid, 2 * ((cap * 1e6) / 2), "no recycling: repayments bounded by the inventories");
        // (d) sequential, one operator, no recycling, unlimited inventory: the requirement
        Cfg memory e = _cfg(string.concat(nm, "/SEQ-NORECYCLE"), cf, cap, n, 3_500);
        e.recycle = false;
        e.logRounds = false;
        Res memory re = _fresh(e);
        assertEq(re.repaid, ra.repaid, "same repayments");
        emit log_string(
            string.concat("FUND|", nm, "|noRecycle=", vm.toString(re.repaid), "|withRecycle(1 operator, sequence)=", vm.toString(ra.peakNeed[0]), "|difference=", vm.toString(re.repaid - ra.peakNeed[0]))
        );
        // verify the with-recycling requirement exactly
        Cfg memory f = _cfg(string.concat(nm, "/SEQ-exact"), cf, cap, n, 3_500);
        f.invA = ra.peakNeed[0];
        f.logRounds = false;
        Res memory rf = _fresh(f);
        assertEq(rf.unfunded, 0, "peak need funds every step");
        assertEq(rf.shortfallAccts, 0, "cleared");
        f.invA = ra.peakNeed[0] - 1;
        assertGt(_fresh(f).unfunded, 0, "one unit less leaves a step unfunded");
    }

    function test_case2_concurrent_PW30() public {
        if (address(controller) == address(0)) return;
        uint256[3] memory caps = [uint256(1_000), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _case2(3000, caps[i], 3);
            _case2(3000, caps[i], 5);
        }
    }

    function test_case2_concurrent_PW40() public {
        if (address(controller) == address(0)) return;
        uint256[3] memory caps = [uint256(1_000), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _case2(4000, caps[i], 3);
            _case2(4000, caps[i], 5);
        }
    }

    // ================================================================= CASE 3: one operator unavailable (A down, B must cover everything)
    function _case3(uint256 cf, uint256 cap, uint256 n, uint256 invDivisor, bool recycle) internal {
        string memory nm = _name(cf, cap, string.concat("gap3500/n", vm.toString(n), "/B-only/inv=cap/", vm.toString(invDivisor), recycle ? "/RECYCLE" : "/NORECYCLE"));
        Cfg memory c = _cfg(nm, cf, cap, n, 3_500);
        c.aUp = false;
        c.bUp = true;
        c.invA = 0;
        c.invB = (cap * 1e6) / invDivisor;
        c.recycle = recycle;
        c.stage2Bp = 6_000; // further fall to -60% from the pin: bad debt of what B could not clear (decision-table tail step)
        c.logRounds = false;
        Res memory r = _fresh(c);
        // reference: everything cleared (A available too, unlimited)
        emit log_string(string.concat("CASE3|", nm, "|", _sum(r), "|S2:acctsInShortfall=", vm.toString(r.shortfallAcctsS2), ",bad6=", vm.toString(r.bad6S2)));
        assertEq(r.invEndA, 0, "operator A (unavailable) held and received nothing");
        if (r.shortfallAccts == 0) assertEq(r.debtLeft > 0 ? r.bad6 : 0, 0, "cleared accounts leave no bad debt at the gapped price");
        else assertGt(r.unfunded, 0, "accounts remain only because the inventory ran out");
    }

    function _case3All(uint256 cf) internal {
        uint256[3] memory caps = [uint256(1_000), 5_000, 10_000];
        for (uint256 i; i < 3; ++i) {
            _case3(cf, caps[i], 5, 2, true); // B holds the first round (cap/2) and recycles
            _case3(cf, caps[i], 5, 2, false); // same, no recycling
            _case3(cf, caps[i], 5, 4, true); // B holds only cap/4
            _case3(cf, caps[i], 3, 2, true);
            _case3(cf, caps[i], 3, 2, false);
        }
    }

    function test_case3_oneOperatorUnavailable_PW30() public {
        if (address(controller) == address(0)) return;
        _case3All(3000);
    }

    function test_case3_oneOperatorUnavailable_PW40() public {
        if (address(controller) == address(0)) return;
        _case3All(4000);
    }

    // ================================================================= CASE 5: min-out limit blocks the conversion (adverse slippage)
    function _case5(uint256 cf, uint256 cap, uint256 n, uint256 invDivisor, uint256 adverse, uint256 limit, bool withFallback) internal {
        string memory nm = _name(
            cf, cap,
            string.concat("gap3500/n", vm.toString(n), "/inv=cap/", vm.toString(invDivisor), "/adverse", vm.toString(adverse), "bp/limit", vm.toString(limit), "bp", withFallback ? "/FALLBACK" : "/nofallback")
        );
        Cfg memory c = _cfg(nm, cf, cap, n, 3_500);
        c.invA = (cap * 1e6) / invDivisor;
        c.adverseBp = adverse;
        c.limitBp = limit;
        c.fallbackRoute = withFallback ? SECOND : NONE;
        Res memory r = _fresh(c);
        emit log_string(string.concat("CASE5|", nm, "|", _sum(r), "|worstOutVsOracleBp=", vm.toString(r.minRatioBp == type(uint256).max ? 0 : r.minRatioBp)));
        if (adverse >= limit + 20 && !withFallback) {
            assertGt(r.blocked, 0, "the limit blocks the conversion");
            assertEq(r.swaps, 0, "no conversion happened");
            assertGt(r.wavaxHeld, 0, "the operator is left holding WAVAX");
        }
    }

    function _case5All(uint256 cf) internal {
        // adverse 300 bp vs limit 100 bp: blocked. Inventory = first round only, so the 2nd round cannot be funded.
        _case5(cf, 5_000, 1, 2, 300, 100, false);
        // inventory 1.0 x cap: the second round is still funded without any conversion
        _case5(cf, 5_000, 1, 1, 300, 100, false);
        // five borrowers, first-round inventory
        _case5(cf, 5_000, 5, 2, 300, 100, false);
        // a second route takes over when the first is blocked
        _case5(cf, 5_000, 5, 2, 300, 100, true);
        // control: the adverse move (30 bp) stays inside the 100 bp limit
        _case5(cf, 5_000, 1, 2, 30, 100, false);
        // the 50 bp limit with a 100 bp adverse move
        _case5(cf, 5_000, 1, 2, 100, 50, false);
    }

    function test_case5_minOutBlocks_PW30() public {
        if (address(controller) == address(0)) return;
        _case5All(3000);
    }

    function test_case5_minOutBlocks_PW40() public {
        if (address(controller) == address(0)) return;
        _case5All(4000);
    }
}
