// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultShareModel} from "./prototype/VaultShareModel.sol";

/// @title AvalancheVaultSharePricingPrototype
/// @notice PURE tests (no RPC) of a STANDALONE MODEL of the Pharaoh vault share accounting and of candidate remedies.
///         Nothing here is deployable code and nothing calls the deployed vault. Method and results:
///         docs/deployment-handoffs/avalanche-vault-share-pricing-remedy.md
///
///         Every assertion is either an exact identity (ledger residual == 0, closed form of the model's own rule) or a
///         bound derived from integer rounding ONLY (floors in the pro-rata claims, the floor of the mint, the `+1` virtual
///         offsets). The bound derivations are in the comments of `_flBound`, `_depBound` and `_tolT`.
///         No tolerance is a tuned percentage. Where a remedy leaves a residual that is NOT rounding (R2: composition
///         mismatch from the deployment swap's cost; R1/R3 with valuation != real position), the residual has its own exact
///         closed form which is asserted instead of a bound.
contract AvalancheVaultSharePricingPrototype is Test {
    using Math for uint256;

    VaultShareModel.Rule constant CUR = VaultShareModel.Rule.CURRENT;
    VaultShareModel.Rule constant R1 = VaultShareModel.Rule.R1;
    VaultShareModel.Rule constant R2 = VaultShareModel.Rule.R2;
    VaultShareModel.Rule constant R3 = VaultShareModel.Rule.R3;
    VaultShareModel.Rule constant MUT_A = VaultShareModel.Rule.MUT_ASYM_NET;
    VaultShareModel.Rule constant MUT_D = VaultShareModel.Rule.MUT_DENOM_HAIRCUT;

    address constant SEED = address(0x5EED);
    address constant ALICE = address(0xA11CE);
    address constant CAROL = address(0xCA201);
    address constant BOB = address(0xB0B);
    address constant DAVE = address(0xDA7E);
    address constant DONOR = address(0xD0D0);

    struct Prof {
        string vaultName; // product name
        string pair; // the correlated pair the vault holds
        string depositedAsset;
        uint256 unit;
        uint256 q;
        uint16 h;
        uint16 slip;
        uint256 fee;
        int256 beta;
        uint256 depth;
    }

    /// Pharaoh USDC vault: pair USDC/USDt, deposited asset USDC, haircut 1%, pool fee 50 ppm, pool 126 ppm below the oracle.
    function _usdc() internal pure returns (Prof memory p) {
        p = Prof("Pharaoh USDC vault", "USDC/USDt", "USDC", 1e6, 0.9996e18, 100, 50, 50, -126, 6.7e13);
    }

    /// Pharaoh WAVAX vault: pair sAVAX/WAVAX, deposited asset WAVAX, haircut 3%, pool fee 100 ppm, pool 1,714 ppm below the oracle.
    function _wavax() internal pure returns (Prof memory p) {
        p = Prof("Pharaoh WAVAX vault", "sAVAX/WAVAX", "WAVAX", 1e18, 1.1717e18, 300, 100, 100, -1714, 6e24);
    }

    function _mk(VaultShareModel.Rule r, Prof memory p) internal returns (VaultShareModel m) {
        m = new VaultShareModel(r, p.q, p.h, p.slip, p.fee, p.beta, p.depth);
    }

    /// @dev Vault of ~1,000 whole asset units: `ib` = idle paired token as bps of value; `pb` = paired share of the
    ///      POSITION's value (the position ratio); `pps` = ownership value per share in bps (10000 = 1.0); incumbents
    ///      SEED 3%, ALICE 47%, CAROL 50% of the shares.
    function _genesis(VaultShareModel.Rule r, Prof memory p, uint256 ib, uint256 pb, uint256 pps)
        internal
        returns (VaultShareModel m)
    {
        m = _mk(r, p);
        uint256 N = 1000 * p.unit;
        uint256 idlePv = N * ib / 1e4;
        uint256 posV = N - idlePv;
        uint256 posPv = posV * pb / 1e4;
        uint256 iP = Math.mulDiv(idlePv, 1e18, p.q);
        uint256 pP = Math.mulDiv(posPv, 1e18, p.q);
        uint256 pA = posV - posPv;
        address[] memory hs = new address[](3);
        uint256[] memory sh = new uint256[](3);
        hs[0] = SEED;
        hs[1] = ALICE;
        hs[2] = CAROL;
        uint256 nav0 = pA + Math.mulDiv(iP + pP, p.q, 1e18);
        uint256 S0 = Math.mulDiv(nav0, 1e4, pps);
        sh[0] = S0 * 300 / 1e4;
        sh[1] = S0 * 4700 / 1e4;
        sh[2] = S0 - sh[0] - sh[1];
        m.genesis(0, iP, pA, pP, pA + pP, hs, sh);
    }

    // ------------------------------------------------------------------ bounds (rounding only)
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    /// @dev fl bounds |entitlementValue - exact pro-rata value| of ONE holder's claim, derived from the floors in
    ///      `_entitlement`: idle asset floor (<1 unit), position asset amount floor (<1 unit), liquidity floor (<1
    ///      liquidity unit, worth posValue/liq units), idle paired floor (<1 paired unit = ceil(q) asset units),
    ///      position paired floor (<1), paired liquidity unit, and the oracle quote floor (<1) applied once to the
    ///      aggregate. A further <1 unit appears because aggregate qPA(P) differs from the sum of component floors.
    function _flBound(VaultShareModel m) internal view returns (uint256) {
        uint256 qc = (m.qWad() + 1e18 - 1) / 1e18;
        uint256 liq = m.liq();
        uint256 unitLiq = liq == 0 ? 0 : (m.posA() + m.qPA(m.posP()) + liq - 1) / liq;
        return 4 + 4 * qc + 2 * unitLiq + 2;
    }

    /// @dev Bound on one incumbent's change of in-kind oracle value across ONE deposit of a mint rule with basis NAV
    ///      N0 -> N1 and shares S0 -> S1, derived (not fitted):
    ///      m = floor(a (S0+1)/(N0+1)), a = N1-N0. With m = m* + d, ideal pro-rata value s H/S:
    ///        change of ideal = s/(S0 S1) [ a (S0-N0)/(N0+1) + N0 delta ],  delta in [0,1) is the mint floor.
    ///      so |change of ideal| <= (s a /S1)(|S0-N0|/(N0+1))/S0 + (s/S1)(N0/S0); plus fl for each end's floors.
    function _depBound(VaultShareModel m, uint256 s, uint256 S0, uint256 S1, uint256 N0, uint256 N1)
        internal
        view
        returns (uint256)
    {
        uint256 a = N1 - N0;
        uint256 dev = S0 > N0 ? S0 - N0 : N0 - S0;
        uint256 b1 = Math.mulDiv(Math.mulDiv(Math.mulDiv(s, a, S1), dev, N0 + 1), 1, S0) + 1;
        uint256 b2 = Math.mulDiv(Math.mulDiv(s, N0, S1), 1, S0) + 1;
        return 2 * _flBound(m) + b1 + b2 + 1;
    }

    /// @dev Tolerance for |actual newcomer transfer - continuous closed form|: the closed form is the continuous mint
    ///      m_c = a S0/N0; the model mints m = m_c + a (N0-S0)/(N0 (N0+1)) - delta. d(E)/d(m) <= H1/S1.
    function _tolT(VaultShareModel m, uint256 S1, uint256 N0, uint256 S0, uint256 a, uint256 H1)
        internal
        view
        returns (uint256)
    {
        uint256 dev = S0 > N0 ? S0 - N0 : N0 - S0;
        uint256 dm = Math.mulDiv(Math.mulDiv(a, dev, N0), 1, N0) + 2;
        return 2 * _flBound(m) + (H1 / S1 + 1) * dm + 1;
    }

    // ------------------------------------------------------------------ single deposit measurement
    struct Dep {
        int256[3] dE; // SEED, ALICE, CAROL change of in-kind oracle value
        uint256[3] B; // rounding bound for each
        int256 T; // newcomer transfer = value of his in-kind entitlement - value of his contribution K
        int256 Tcf; // continuous closed form from the observed K
        uint256 tolT;
        int256 K; // Hk
        uint256 D;
        uint256 minted;
        int256 costVal; // value cost of the deployment swap(s): input value - oracle value of output, signed
        int256 sumInc; // sum of the three incumbents' changes
    }

    function _incs() internal pure returns (address[3] memory a) {
        a[0] = SEED;
        a[1] = ALICE;
        a[2] = CAROL;
    }

    function _closedForm(VaultShareModel m, int256 Hk, int256 Pk, uint256 H1, uint256 P1) internal view returns (int256) {
        int256 h = int256(uint256(m.hBps()));
        int256 num = h * (Hk * int256(P1) - Pk * int256(H1));
        int256 den = 1e4 * int256(H1) - h * int256(P1);
        return num / den;
    }

    function _deposit(VaultShareModel m, address who, uint256 D) internal returns (Dep memory r) {
        address[3] memory incs = _incs();
        uint256[3] memory E0;
        uint256[3] memory sh;
        for (uint256 i; i < 3; ++i) {
            E0[i] = m.entitlementValue(incs[i]);
            sh[i] = m.shares(incs[i]);
        }
        uint256 H0 = m.holdingsValue();
        (, uint256 P0t) = m.holdings();
        uint256 P0 = m.qPA(P0t);
        uint256 S0 = m.supply();
        bool hc = m.rule() == CUR || m.rule() == R2;
        uint256 N0 = m.nav(hc);
        r.D = D;
        m.faucet(who, D, 0);
        int256 poolA0 = m.poolNetA();
        int256 poolP0 = m.poolNetP();
        r.minted = m.deposit(who, D);
        uint256 N1 = m.nav(hc);
        uint256 S1 = m.supply();
        uint256 H1 = m.holdingsValue();
        (, uint256 P1t) = m.holdings();
        uint256 P1 = m.qPA(P1t);
        for (uint256 i; i < 3; ++i) {
            r.dE[i] = int256(m.entitlementValue(incs[i])) - int256(E0[i]);
            r.B[i] = _depBound(m, sh[i], S0, S1, N0, N1);
            r.sumInc += r.dE[i];
        }
        r.K = int256(H1) - int256(H0);
        int256 Pk = int256(P1) - int256(P0);
        r.T = int256(m.entitlementValue(who)) - r.K;
        r.Tcf = _closedForm(m, r.K, Pk, H1, P1);
        r.tolT = _tolT(m, S1, N0, S0, N1 - N0, H1);
        // value cost of the swaps: asset given to the pool minus oracle value of paired received (and the reverse)
        int256 dA = m.poolNetA() - poolA0;
        int256 dP = m.poolNetP() - poolP0;
        // pool received dA asset and dP paired (dP negative when it paid paired out): cost = dA + oracle(dP)
        r.costVal = dA + (dP >= 0 ? int256(m.qPA(uint256(dP))) : -int256(m.qPA(uint256(-dP))));
    }

    function _ledger(VaultShareModel m) internal view {
        assertEq(m.ledgerResidualA(), 0, "asset ledger residual");
        assertEq(m.ledgerResidualP(), 0, "paired ledger residual");
    }

    // =================================================================================================================
    // 0. The model reproduces the derivation EXACTLY (so that "the current rule fails" is a statement about the rule)
    // =================================================================================================================

    /// The closed form T = h (K P1 - kP H1) / (1e4 H1 - h P1) (K, kP signed) equals the model's CURRENT-rule transfer
    /// to within the derived rounding tolerance for every inventory, deposit size and share-price level of the grid.
    /// Includes the regime where kP < 0 (the vault sells incumbents' idle paired token for a small deposit).
    function test_00a_currentRule_matchesClosedForm_grid_usdc() public { _t00(_usdc()); }
    function test_00b_currentRule_matchesClosedForm_grid_wavax() public { _t00(_wavax()); }

    function _t00(Prof memory pp) internal {
        Prof[2] memory ps = [pp, pp];
        uint256[4] memory ibs = [uint256(0), 300, 1500, 5000];
        uint256[3] memory pbs = [uint256(3000), 5000, 7000];
        uint256[4] memory deps = [uint256(100), 1000, 10000, 30000];
        uint256[3] memory ppss = [uint256(10000), 9700, 10300];
        uint256 n;
        uint256 neg;
        uint256 maxDiff;
        for (uint256 a; a < 1; ++a) {
            for (uint256 b; b < 4; ++b) {
                for (uint256 c; c < 3; ++c) {
                    for (uint256 d; d < 4; ++d) {
                        for (uint256 e; e < 3; ++e) {
                            VaultShareModel m = _genesis(CUR, ps[a], ibs[b], pbs[c], ppss[e]);
                            Dep memory r = _deposit(m, BOB, ps[a].unit * 1000 * deps[d] / 10000);
                            uint256 diff = _abs(r.T - r.Tcf);
                            assertLe(diff, r.tolT, "closed form vs model");
                            if (diff > maxDiff) maxDiff = diff;
                            if (r.costVal < 0 || r.T < 0) neg++;
                            _ledger(m);
                            n++;
                        }
                    }
                }
            }
        }
        console2.log(string.concat("PROTO|00 closed form matches model in ", vm.toString(n), " cases, max |T-Tcf| (asset raw units) ", vm.toString(maxDiff), "; cases with T<0 or negative swap cost ", vm.toString(neg)));
    }

    // =================================================================================================================
    // 1. (i) incumbent protection grid (single deposit): every rule, discriminating
    // =================================================================================================================

    struct Tally {
        uint256 cases;
        uint256 violations; // cases where some incumbent moved by more than its rounding bound
        uint256 maxRatioPpm; // max |dE| / B (ppm), the closeness to the bound
        uint256 maxTppm; // max |T| in ppm of D
        uint256 maxIncLossPpm; // max incumbent loss in ppm of its own value (positive = loss)
        int256 maxLossAtIdle;
        uint256 worstIb;
        uint256 worstPb;
        uint256 worstDep;
    }

    function _grid(VaultShareModel.Rule r, Prof memory p, bool assertProtection) internal returns (Tally memory t) {
        uint256[4] memory ibs = [uint256(0), 300, 1500, 5000];
        uint256[3] memory pbs = [uint256(3000), 5000, 7000];
        uint256[4] memory deps = [uint256(100), 1000, 10000, 30000];
        uint256[3] memory ppss = [uint256(10000), 9700, 10300];
        for (uint256 b; b < 4; ++b) {
            for (uint256 c; c < 3; ++c) {
                for (uint256 d; d < 4; ++d) {
                    for (uint256 e; e < 3; ++e) {
                        VaultShareModel m = _genesis(r, p, ibs[b], pbs[c], ppss[e]);
                        uint256[3] memory E0;
                        address[3] memory incs = _incs();
                        for (uint256 i; i < 3; ++i) E0[i] = m.entitlementValue(incs[i]);
                        Dep memory x = _deposit(m, BOB, p.unit * 1000 * deps[d] / 10000);
                        _ledger(m);
                        t.cases++;
                        bool viol;
                        for (uint256 i; i < 3; ++i) {
                            uint256 ad = _abs(x.dE[i]);
                            if (ad > x.B[i]) viol = true;
                            uint256 ratio = Math.mulDiv(ad, 1e6, x.B[i]);
                            if (ratio > t.maxRatioPpm) t.maxRatioPpm = ratio;
                            if (x.dE[i] < 0) {
                                uint256 loss = Math.mulDiv(uint256(-x.dE[i]), 1e6, E0[i]);
                                if (loss > t.maxIncLossPpm) t.maxIncLossPpm = loss;
                            }
                        }
                        uint256 tppm = Math.mulDiv(_abs(x.T), 1e6, x.D);
                        if (tppm > t.maxTppm) {
                            t.maxTppm = tppm;
                            t.worstIb = ibs[b];
                            t.worstPb = pbs[c];
                            t.worstDep = deps[d];
                        }
                        // ledger of value: incumbents + newcomer = K up to the per-holder floors (4 holders)
                        assertLe(_abs(x.sumInc + x.T), 4 * _flBound(m) + 4, "value ledger: incumbents + newcomer != K");
                        if (viol) t.violations++;
                        if (assertProtection) assertFalse(viol, "incumbent moved by more than rounding");
                    }
                }
            }
        }
    }

    function _logTally(string memory tag, Prof memory p, Tally memory t) internal pure {
        console2.log(
            string.concat(
                "PROTO|GRID ", tag, " | ", p.vaultName, " (pair ", p.pair, ", deposited ", p.depositedAsset, ") cases=", vm.toString(t.cases),
                " violations=", vm.toString(t.violations), " max|dE|/bound(ppm)=", vm.toString(t.maxRatioPpm),
                " max|T|/D(ppm)=", vm.toString(t.maxTppm), " max incumbent loss(ppm)=", vm.toString(t.maxIncLossPpm),
                " worst ib/pb/dep(bps)=", vm.toString(t.worstIb), "/", vm.toString(t.worstPb), "/", vm.toString(t.worstDep)
            )
        );
    }

    function test_01_grid_R1_protects_every_incumbent() public {
        Tally memory a = _grid(R1, _usdc(), true);
        Tally memory b = _grid(R1, _wavax(), true);
        _logTally("R1", _usdc(), a);
        _logTally("R1", _wavax(), b);
        assertEq(a.violations + b.violations, 0);
    }

    function test_02_grid_R3_protects_every_incumbent() public {
        Tally memory a = _grid(R3, _usdc(), true);
        Tally memory b = _grid(R3, _wavax(), true);
        _logTally("R3", _usdc(), a);
        _logTally("R3", _wavax(), b);
        assertEq(a.violations + b.violations, 0);
    }

    /// R2 keeps the haircut mint; its transfer is not rounding but has the exact closed form
    ///   T = h costVal A0 / (1e4 H1 - h P1)
    /// (cost of the deployment swap times the vault's asset-valued part; derivation in the doc, section 5.2).
    function test_03_R2_transfer_equals_its_own_closed_form_and_is_second_order() public {
        Prof[2] memory ps = [_usdc(), _wavax()];
        uint256[4] memory ibs = [uint256(0), 300, 1500, 5000];
        uint256[3] memory pbs = [uint256(3000), 5000, 7000];
        uint256[4] memory deps = [uint256(100), 1000, 10000, 30000];
        for (uint256 a; a < 2; ++a) {
            uint256 maxT;
            uint256 maxLoss;
            uint256 n;
            for (uint256 b; b < 4; ++b) {
                for (uint256 c; c < 3; ++c) {
                    for (uint256 d; d < 4; ++d) {
                        VaultShareModel m = _genesis(R2, ps[a], ibs[b], pbs[c], 10000);
                        uint256 A0 = m.holdingsValue() - m.qPA(m.idleP() + m.posP());
                        Dep memory x = _deposit(m, BOB, ps[a].unit * 1000 * deps[d] / 10000);
                        _ledger(m);
                        // pred = h * costVal * A0 / (1e4 H1 - h P1)
                        uint256 H1 = m.holdingsValue();
                        uint256 P1 = m.qPA(m.idleP() + m.posP());
                        int256 pred = int256(uint256(m.hBps())) * x.costVal * int256(A0)
                            / (1e4 * int256(H1) - int256(uint256(m.hBps())) * int256(P1));
                        // the costVal of the model counts the swap loss in the same units; floors: 3 fl
                        assertLe(_abs(x.T - pred), x.tolT + 3 * _flBound(m), "R2 closed form");
                        uint256 tp = Math.mulDiv(_abs(x.T), 1e6, x.D);
                        if (tp > maxT) maxT = tp;
                        for (uint256 i; i < 3; ++i) {
                            if (x.dE[i] < 0) {
                                uint256 l = Math.mulDiv(uint256(-x.dE[i]), 1e6, ps[a].unit * 1000 * (i == 0 ? 3 : (i == 1 ? 47 : 50)) / 100);
                                if (l > maxLoss) maxLoss = l;
                            }
                        }
                        n++;
                    }
                }
            }
            console2.log(string.concat("PROTO|R2 ", ps[a].vaultName, " (", ps[a].pair, ", deposited ", ps[a].depositedAsset, ") ", vm.toString(n), " cases, max |T|/D (ppm) ", vm.toString(maxT), ", max incumbent loss (ppm of its value) ", vm.toString(maxLoss)));
        }
    }

    /// The deployed rule FAILS the same grid, and the failure is where the closed form says it is.
    function test_04_grid_CURRENT_fails() public {
        Tally memory a = _grid(CUR, _usdc(), false);
        Tally memory b = _grid(CUR, _wavax(), false);
        _logTally("CURRENT", _usdc(), a);
        _logTally("CURRENT", _wavax(), b);
        assertGt(a.violations, 0, "usdc: the current rule must fail somewhere");
        assertGt(b.violations, 0, "wavax: the current rule must fail somewhere");
        // largest transfer exceeds 100 ppm of the deposit on the WAVAX vault (h = 3%) -- logged, and asserted as a discriminator
        assertGt(b.maxTppm, 10_000, "wavax: transfer reaches > 1% of the deposit in some state");
    }

    /// Mutations of R1 are caught by the protection check (one test per mutation and vault: each runs a 144-case grid).
    function _mutCaught(VaultShareModel.Rule r, Prof memory p, string memory tag) internal {
        Tally memory t = _grid(r, p, false);
        _logTally(tag, p, t);
        assertGt(t.violations, 0, string.concat("mutation not caught: ", tag));
    }

    function test_05a_mutation_asymmetricNetHaircut_caught_wavax() public { _mutCaught(MUT_A, _wavax(), "MUT_ASYM_NET"); }
    function test_05b_mutation_asymmetricNetHaircut_caught_usdc() public { _mutCaught(MUT_A, _usdc(), "MUT_ASYM_NET"); }
    function test_05c_mutation_haircutDenominator_caught_wavax() public { _mutCaught(MUT_D, _wavax(), "MUT_DENOM_HAIRCUT"); }
    function test_05d_mutation_haircutDenominator_caught_usdc() public { _mutCaught(MUT_D, _usdc(), "MUT_DENOM_HAIRCUT"); }

    // =================================================================================================================
    // 2. R1/R3 residual when the valuation position differs from the real position (TWAP tick != spot tick)
    // =================================================================================================================

    /// With valuation skew s, the ownership NAV Nv differs from the real value; the transfer is exactly
    ///   T = H1 (Nv1 - Nv0)/Nv1 - K   (continuous), asserted equal to the model within the mint tolerance.
    /// It is zero for s = 0 and grows with |s| and with the deposit size; it is NOT rounding and is not hidden.
    function test_06_valuation_gap_residual_has_exact_form() public {
        Prof memory p = _wavax();
        int256[4] memory skews = [int256(0), 200, 1000, -1000];
        for (uint256 k; k < 4; ++k) {
            VaultShareModel m = _genesis(R1, p, 1500, 5000, 10000);
            m.setValuationSkew(skews[k]);
            uint256 N0 = m.nav(false);
            uint256 H0 = m.holdingsValue();
            Dep memory x = _deposit(m, BOB, p.unit * 1000 * 1000 / 10000);
            uint256 N1 = m.nav(false);
            uint256 H1 = m.holdingsValue();
            uint256 S0 = m.supply() - x.minted;
            int256 pred = int256(Math.mulDiv(H1, N1 - N0, N1)) - (int256(H1) - int256(H0));
            assertLe(_abs(x.T - pred), _tolT(m, m.supply(), N0, S0, N1 - N0, H1), "valuation gap form");
            if (k == 0) assertLe(_abs(x.T), x.tolT, "no gap => rounding only");
            console2.log(string.concat("PROTO|06 R1 valuation skew bps ", vm.toString(skews[k]), " -> T (raw) ", vm.toString(x.T), " ppm of D ", vm.toString(x.T * 1e6 / int256(x.D))));
            _ledger(m);
        }
    }

    // =================================================================================================================
    // 3. Sequences: more than two holders, orderings, mixed exits, replenishment (iii) (iv) (v)
    // =================================================================================================================

    enum K {
        DEP,
        EXIT_KIND,
        EXIT_REAL,
        EXIT_HAIR,
        DONATE,
        KEEPER
    }

    struct Op {
        K kind;
        address who;
        uint256 bps; // DEP: bps of current ownership NAV; EXIT_*: bps of the holder's shares; DONATE: bps of NAV in paired value
    }

    struct SeqRes {
        uint256 violations; // exits/deposits where a non-actor holder moved by more than its bound
        uint256 haircutExitOps;
        int256 stayerGainFromHaircutExits; // sum of stayers' gains over EXIT_HAIR ops (asset raw units)
        uint256 maxDepTppm;
        uint256 ops;
    }

    function _sequence(VaultShareModel m, Op[] memory ops, bool assertBounds) internal returns (SeqRes memory res) {
        address[5] memory hs = [SEED, ALICE, CAROL, BOB, DAVE];
        for (uint256 o; o < ops.length; ++o) {
            Op memory op = ops[o];
            uint256[5] memory E0;
            uint256[5] memory sh0;
            for (uint256 i; i < 5; ++i) {
                E0[i] = m.entitlementValue(hs[i]);
                sh0[i] = m.shares(hs[i]);
            }
            uint256 S0 = m.supply();
            bool hc = m.rule() == CUR || m.rule() == R2;
            uint256 N0 = m.nav(hc);
            uint256 H0 = m.holdingsValue();
            uint256 fl = _flBound(m);
            int256 poolPA = m.poolNetP();
            int256 poolAA = m.poolNetA();
            uint256 entX; // exiter's entitlement value for the exited shares (HAIR identity)
            uint256 paid;
            if (op.kind == K.DEP) {
                uint256 D = N0 * op.bps / 1e4;
                m.faucet(op.who, D, 0);
                m.deposit(op.who, D);
            } else if (op.kind == K.DONATE) {
                uint256 pv = N0 * op.bps / 1e4;
                uint256 pp = m.qAP(pv);
                m.faucet(DONOR, 0, pp);
                m.donate(DONOR, 0, pp);
            } else if (op.kind == K.KEEPER) {
                m.keeperDeployIdle();
            } else {
                uint256 sh = sh0[_idx(hs, op.who)] * op.bps / 1e4;
                if (sh == 0) sh = 1;
                (uint256 ea, uint256 ep) = _entOf(m, sh);
                entX = ea + m.qPA(ep);
                if (op.kind == K.EXIT_KIND) {
                    m.redeemInKind(op.who, sh);
                } else if (op.kind == K.EXIT_REAL) {
                    paid = m.redeemCash(op.who, sh, VaultShareModel.CashMode.REALIZED);
                } else {
                    paid = m.redeemCash(op.who, sh, VaultShareModel.CashMode.HAIRCUT);
                }
            }
            _ledger(m);
            res.ops++;
            uint256 S1 = m.supply();
            uint256 N1 = m.nav(hc);
            // non-actor holders
            int256 stayers;
            for (uint256 i; i < 5; ++i) {
                if (sh0[i] == 0 || hs[i] == op.who) continue;
                int256 dE = int256(m.entitlementValue(hs[i])) - int256(E0[i]);
                stayers += dE;
                if (op.kind == K.DEP) {
                    uint256 B = _depBound(m, sh0[i], S0, S1, N0, N1);
                    if (_abs(dE) > B) {
                        res.violations++;
                        if (assertBounds) assertLe(_abs(dE), B, "deposit moved a holder by more than rounding");
                    }
                } else if (op.kind == K.EXIT_KIND || op.kind == K.EXIT_REAL) {
                    uint256 B = 3 * fl;
                    if (_abs(dE) > B) {
                        res.violations++;
                        if (assertBounds) assertLe(_abs(dE), B, "pure/realised exit moved a holder by more than rounding");
                    }
                }
            }
            if (op.kind == K.EXIT_HAIR) {
                res.haircutExitOps++;
                res.stayerGainFromHaircutExits += stayers;
                // exact identity: sum(stayers) = (entitlement of the exited shares - cash paid) - swap cost; swap cost = oracle
                // value of the paired the pool received minus the asset it paid (from the pool ledger)
                int256 dP = m.poolNetP() - poolPA;
                int256 dA = m.poolNetA() - poolAA;
                int256 cost = dA + (dP >= 0 ? int256(m.qPA(uint256(dP))) : -int256(m.qPA(uint256(-dP))));
                int256 pred = int256(entX) - int256(paid) - cost;
                // the exiter's REMAINING shares are also "left in the vault": add their change
                uint256 ia = _idx(hs, op.who);
                stayers += int256(m.entitlementValue(op.who)) - (int256(E0[ia]) - int256(entX));
                // NOTE: assets already idle are paid first; the vault's remaining holders' total change equals pred.
                assertLe(_abs(stayers - pred), 6 * fl + 8, "haircut cash exit identity");
            }
        }
    }

    function _entOf(VaultShareModel m, uint256 sh) internal view returns (uint256 a, uint256 p) {
        // replicate the pro-rata claim of `sh` shares (same floors as redeemInKind)
        uint256 S = m.supply();
        a = Math.mulDiv(m.idleA(), sh, S);
        p = Math.mulDiv(m.idleP(), sh, S);
        uint256 lr = sh == S ? m.liq() : Math.mulDiv(m.liq(), sh, S);
        if (lr > 0) {
            a += lr == m.liq() ? m.posA() : Math.mulDiv(m.posA(), lr, m.liq());
            p += lr == m.liq() ? m.posP() : Math.mulDiv(m.posP(), lr, m.liq());
        }
    }

    function _idx(address[5] memory hs, address w) internal pure returns (uint256) {
        for (uint256 i; i < 5; ++i) {
            if (hs[i] == w) return i;
        }
        revert("who");
    }

    function _seq(uint256 id) internal pure returns (Op[] memory ops) {
        if (id == 0) {
            // small then large, exits in the middle
            ops = new Op[](6);
            ops[0] = Op(K.DEP, BOB, 1000);
            ops[1] = Op(K.DEP, DAVE, 10000);
            ops[2] = Op(K.EXIT_KIND, BOB, 10000);
            ops[3] = Op(K.EXIT_KIND, DAVE, 10000);
            ops[4] = Op(K.EXIT_KIND, ALICE, 5000);
            ops[5] = Op(K.EXIT_KIND, CAROL, 10000);
        } else if (id == 1) {
            // large then small
            ops = new Op[](5);
            ops[0] = Op(K.DEP, DAVE, 10000);
            ops[1] = Op(K.DEP, BOB, 1000);
            ops[2] = Op(K.EXIT_KIND, DAVE, 10000);
            ops[3] = Op(K.DEP, DAVE, 100);
            ops[4] = Op(K.EXIT_KIND, BOB, 10000);
        } else if (id == 2) {
            // interleaved, partial exits
            ops = new Op[](7);
            ops[0] = Op(K.DEP, BOB, 10000);
            ops[1] = Op(K.EXIT_KIND, ALICE, 5000);
            ops[2] = Op(K.DEP, DAVE, 1000);
            ops[3] = Op(K.EXIT_KIND, BOB, 5000);
            ops[4] = Op(K.EXIT_KIND, DAVE, 10000);
            ops[5] = Op(K.EXIT_KIND, ALICE, 10000);
            ops[6] = Op(K.DEP, BOB, 30000);
        } else if (id == 3) {
            // mixed exits: part in kind, part cash at the realised value (haircut NAV as guard)
            ops = new Op[](5);
            ops[0] = Op(K.DEP, BOB, 5000);
            ops[1] = Op(K.EXIT_KIND, BOB, 4000);
            ops[2] = Op(K.EXIT_REAL, BOB, 5000);
            ops[3] = Op(K.DEP, DAVE, 1000);
            ops[4] = Op(K.EXIT_REAL, DAVE, 10000);
        } else if (id == 4) {
            // replenishment: third parties add idle paired token, keeper redeploys, then more deposits and exits
            ops = new Op[](9);
            ops[0] = Op(K.DEP, BOB, 1000);
            ops[1] = Op(K.DONATE, DONOR, 300);
            ops[2] = Op(K.DEP, DAVE, 1000);
            ops[3] = Op(K.KEEPER, DONOR, 0);
            ops[4] = Op(K.DONATE, DONOR, 1500);
            ops[5] = Op(K.DEP, BOB, 100);
            ops[6] = Op(K.EXIT_KIND, BOB, 10000);
            ops[7] = Op(K.DEP, DAVE, 10000);
            ops[8] = Op(K.EXIT_KIND, DAVE, 10000);
        } else {
            // cash exits at the haircut basis (deployed redeem) mixed with in-kind
            ops = new Op[](5);
            ops[0] = Op(K.DEP, BOB, 5000);
            ops[1] = Op(K.EXIT_KIND, BOB, 4000);
            ops[2] = Op(K.EXIT_HAIR, BOB, 5000);
            ops[3] = Op(K.DEP, DAVE, 2000);
            ops[4] = Op(K.EXIT_HAIR, DAVE, 10000);
        }
    }

    function _runOne(VaultShareModel.Rule r, Prof memory p, uint256 id, uint256 ib, uint256 pb, bool assertBounds)
        internal
        returns (SeqRes memory)
    {
        VaultShareModel m = _genesis(r, p, ib, pb, 10000);
        return _sequence(m, _seq(id), assertBounds);
    }

    function _ib(uint256 k) internal pure returns (uint256) {
        return k == 0 ? 0 : (k == 1 ? 1500 : 5000);
    }

    function _add(SeqRes memory agg, SeqRes memory s) internal pure {
        agg.violations += s.violations;
        agg.ops += s.ops;
        agg.haircutExitOps += s.haircutExitOps;
        agg.stayerGainFromHaircutExits += s.stayerGainFromHaircutExits;
    }

    function _runSeqAll(VaultShareModel.Rule r, Prof memory p, uint256 id, bool assertBounds)
        internal
        returns (SeqRes memory agg)
    {
        for (uint256 k; k < 6; ++k) {
            _add(agg, _runOne(r, p, id, _ib(k / 2), (k % 2 == 0) ? 3000 : 5000, assertBounds));
        }
    }

    function test_10_sequences_R1_R3_protect_all_holders() public {
        Prof[2] memory ps = [_usdc(), _wavax()];
        for (uint256 a; a < 2; ++a) {
            for (uint256 id; id < 5; ++id) {
                SeqRes memory x = _runSeqAll(R1, ps[a], id, true);
                SeqRes memory y = _runSeqAll(R3, ps[a], id, true);
                SeqRes memory z = _runSeqAll(R2, ps[a], id, false);
                console2.log(string.concat("PROTO|SEQ ", ps[a].vaultName, " (", ps[a].pair, ", deposited ", ps[a].depositedAsset, ") seq ", vm.toString(id), " R1 violations ", vm.toString(x.violations), " R3 violations ", vm.toString(y.violations), " R2 (haircut mint, proportional deployment; NOT rounding-only, see test_03) violations ", vm.toString(z.violations), " ops each ", vm.toString(x.ops)));
            }
        }
    }

    function test_11_sequences_CURRENT_fails() public {
        Prof[2] memory ps = [_usdc(), _wavax()];
        for (uint256 a; a < 2; ++a) {
            uint256 total;
            for (uint256 id; id < 5; ++id) {
                SeqRes memory x = _runSeqAll(CUR, ps[a], id, false);
                total += x.violations;
                console2.log(string.concat("PROTO|SEQ CURRENT ", ps[a].vaultName, " seq ", vm.toString(id), " violations ", vm.toString(x.violations)));
            }
            assertGt(total, 0, "the current rule must fail the sequence set");
        }
    }

    /// (iii) The deployed cash exit at the haircut basis is an EXIT FEE in favour of the stayers, exactly
    /// (entitlement of the exited shares - cash paid) - swap cost; the exiter never receives more than the entitlement.
    /// The identity is asserted inside `_sequence`; here the sign and size over the set is recorded.
    function test_12_cashExitAtHaircutBasis_isAnExitFee_identity() public {
        Prof[2] memory ps = [_usdc(), _wavax()];
        for (uint256 a; a < 2; ++a) {
            SeqRes memory x = _runSeqAll(R1, ps[a], 5, false);
            console2.log(string.concat("PROTO|12 ", ps[a].vaultName, " (", ps[a].pair, ", deposited ", ps[a].depositedAsset, ") haircut-basis cash exits ", vm.toString(x.haircutExitOps), " stayers' summed gain (raw units) ", vm.toString(x.stayerGainFromHaircutExits)));
            assertGt(x.haircutExitOps, 0);
        }
    }

    /// (iii) cash exit settled at the realised value moves nothing to or from the others (rounding only); asserted in seq 3.
    /// (v) conservation: `_ledger` after every operation of every sequence (asserted inside `_sequence`).

    // =================================================================================================================
    // 4. (ii) newcomer round trips net of the modelled swap cost
    // =================================================================================================================

    function _roundTrip(VaultShareModel.Rule r, Prof memory p, uint256 ib, uint256 pb, uint256 depBps)
        internal
        returns (int256 net, int256 netPpm, int256 T, uint256 bound)
    {
        VaultShareModel m = _genesis(r, p, ib, pb, 10000);
        uint256 D = p.unit * 1000 * depBps / 10000;
        Dep memory x = _deposit(m, BOB, D);
        T = x.T;
        bound = x.tolT;
        (, uint256 gp) = m.redeemInKind(BOB, m.shares(BOB));
        if (gp > 0) m.walletSellPaired(BOB, gp);
        net = int256(m.walA(BOB)) - int256(D);
        netPpm = net * 1e6 / int256(D);
        _ledger(m);
    }

    struct RT {
        int256 netPpm; // round-trip P&L, ppm of D
        int256 net;
        int256 T;
        uint256 bound;
    }

    function _rt(VaultShareModel.Rule r, Prof memory p, uint256 ib, uint256 pb, uint256 dep) internal returns (RT memory x) {
        (x.net, x.netPpm, x.T, x.bound) = _roundTrip(r, p, ib, pb, dep);
    }

    function _noBasis(Prof memory p) internal pure returns (Prof memory q) {
        q = p;
        q.beta = 0; // pool price == oracle price: no oracle/pool basis
    }

    /// Identity: round-trip P&L = T - costVal(deployment) + (sale proceeds - oracle value of the paired leg sold).
    /// With beta = 0 every term except T is <= 0, so P&L <= T <= rounding. With beta != 0 the "buy below the oracle" credit
    /// -costVal can exceed the cost of selling back a SMALLER paired leg (R1) -- an oracle/pool BASIS term that no
    /// share-pricing rule removes; R3 shrinks it because the newcomer's paired leg then matches what he buys.
    function _rtCase(Prof memory p, uint256 ib, uint256 pb, uint256 dep, int256[3] memory best, bool strict) internal {
        RT memory r1 = _rt(R1, p, ib, pb, dep);
        RT memory r3 = _rt(R3, p, ib, pb, dep);
        RT memory rc = _rt(CUR, p, ib, pb, dep);
        if (strict) {
            assertLe(r1.net, int256(r1.bound), "R1 round trip positive beyond rounding");
            assertLe(r3.net, int256(r3.bound), "R3 round trip positive beyond rounding");
            assertLe(r1.T, int256(r1.bound));
            assertLe(r3.T, int256(r3.bound));
        }
        if (r1.netPpm > best[0]) best[0] = r1.netPpm;
        if (r3.netPpm > best[1]) best[1] = r3.netPpm;
        if (rc.netPpm > best[2]) best[2] = rc.netPpm;
    }

    function _rtGrid(Prof memory p, bool strict) internal returns (int256[3] memory best) {
        uint256[4] memory ibs = [uint256(0), 300, 1500, 5000];
        uint256[3] memory pbs = [uint256(3000), 5000, 7000];
        uint256[4] memory deps = [uint256(100), 1000, 10000, 30000];
        best = [type(int256).min, type(int256).min, type(int256).min]; // R1, R3, CURRENT
        for (uint256 k; k < 48; ++k) {
            _rtCase(p, ibs[k / 12], pbs[(k / 4) % 3], deps[k % 4], best, strict);
        }
    }

    function _logRt(string memory tag, Prof memory p, int256[3] memory best) internal pure {
        console2.log(string.concat("PROTO|20 ", tag, " round trip (deposit, exit in kind, sell the paired leg through the modelled pool) ", p.vaultName, " (", p.pair, ", deposited ", p.depositedAsset, "), best case over the 48-state grid, ppm of D: R1 ", vm.toString(best[0]), " R3 ", vm.toString(best[1]), " CURRENT ", vm.toString(best[2])));
    }

    /// (ii) with no oracle/pool basis: R1 and R3 round trips never exceed rounding; the current rule's does.
    function test_20a_roundTrips_noBasis_usdc() public { _t20(_noBasis(_usdc()), "no-basis"); }
    function test_20b_roundTrips_noBasis_wavax() public { _t20(_noBasis(_wavax()), "no-basis"); }

    function _t20(Prof memory p, string memory tag) internal {
        int256[3] memory best = _rtGrid(p, true);
        _logRt(tag, p, best);
        assertGt(best[2], 0, "the current rule must allow a profitable round trip somewhere");
        assertLt(best[0], 0, "R1 best round trip must lose");
        assertLt(best[1], 0, "R3 best round trip must lose");
    }

    /// With the modelled oracle/pool basis (pool below oracle by 126 / 1,714 ppm) REPORT: the basis is not a share-pricing
    /// effect; asserted: R3 never exceeds its rounding bound; R1 is reported (it can exceed by the basis credit).
    function test_21a_roundTrips_withBasis_usdc() public { _t21(_usdc()); }
    function test_21b_roundTrips_withBasis_wavax() public { _t21(_wavax()); }

    function _t21(Prof memory p) internal {
        int256[3] memory best = _rtGrid(p, false);
        _logRt("with-basis", p, best);
    }

    // =================================================================================================================
    // 5. (iv) / Part 3: repeated cycling with replenished idle balances; reserve drain
    // =================================================================================================================

    uint256[5] internal _RES = [uint256(1_000), 5_000, 10_000, 20_000, 50_000]; // reserves: 0.1%, 0.5%, 1%, 2%, 5% of vault value (ppm)

    struct Cycle {
        uint256 cycles;
        int256 attackerNet; // cumulative, asset raw units
        uint256 incumbentLossCum; // cumulative incumbent loss that a reserve would pay (asset raw units), floored at 0 per cycle
        uint256 firstExhaust; // first cycle at which cumulative loss >= reserve (0 = never within the run)
        uint256 replenished; // oracle value of paired token added by third parties over the run
        uint256[5] first; // first cycle at which the cumulative loss reached reserves[k] (0 = not within the run)
        uint256 boundCum; // cumulative rounding bound of the incumbents' change (3 incumbents, deposit + exit per cycle)
    }

    /// Between cycles a third party adds idle paired token worth `replBps` of the vault (fees collected, a rebalance,
    /// third-party deposits all do this); then the cycling newcomer deposits `dBps` of the vault, exits in kind, and sells
    /// the paired leg through the pool. The "reserve" pays each cycle's incumbent loss, measured AFTER the replenishment.
    function _cycleRun(VaultShareModel.Rule r, Prof memory p, uint256 ib, uint256 dBps, uint256 replBps, uint256 n, uint256 reserveBps)
        internal
        returns (Cycle memory cy)
    {
        VaultShareModel m = _genesis(r, p, ib, 5000, 10000);
        uint256 N = 1000 * p.unit;
        uint256 reserve = N * reserveBps / 1e6; // reserveBps in ppm of vault value here
        uint256 D;
        uint256 startBob;
        uint256 topUp;
        for (uint256 i; i < n; ++i) {
            D = m.nav(false) * dBps / 1e4; // the cycling newcomer deposits dBps of the CURRENT vault value each cycle
            if (i == 0) {
                m.faucet(BOB, D, 0);
                startBob = D;
            }
            if (m.walA(BOB) < D) {
                topUp += D - m.walA(BOB);
                m.faucet(BOB, D - m.walA(BOB), 0);
            }
            if (replBps > 0) {
                // a flow of idle paired token from other sources (collected fees, other depositors' residue, keeper
                // rebalances): a FIXED amount per cycle worth `replBps` of the vault's STARTING value
                uint256 pp = m.qAP(N * replBps / 1e4);
                m.faucet(DONOR, 0, pp);
                m.donate(DONOR, 0, pp);
                cy.replenished += m.qPA(pp);
            }
            uint256 incBefore = m.entitlementValue(SEED) + m.entitlementValue(ALICE) + m.entitlementValue(CAROL);
            uint256 bobA = D; // fixed stake each cycle; winnings stay in his wallet
            uint256 S0c = m.supply();
            bool hcc = r == CUR || r == R2;
            uint256 N0c = m.nav(hcc);
            uint256 flc = _flBound(m);
            uint256[3] memory shc = [m.shares(SEED), m.shares(ALICE), m.shares(CAROL)];
            m.deposit(BOB, bobA);
            for (uint256 j; j < 3; ++j) cy.boundCum += _depBound(m, shc[j], S0c, m.supply(), N0c, m.nav(hcc)) + 3 * flc;
            (, uint256 gp) = m.redeemInKind(BOB, m.shares(BOB));
            if (gp > 0) m.walletSellPaired(BOB, gp);
            uint256 incAfter = m.entitlementValue(SEED) + m.entitlementValue(ALICE) + m.entitlementValue(CAROL);
            if (incAfter < incBefore) cy.incumbentLossCum += incBefore - incAfter;
            cy.cycles++;
            if (cy.firstExhaust == 0 && cy.incumbentLossCum >= reserve) cy.firstExhaust = i + 1;
            for (uint256 k; k < 5; ++k) {
                if (cy.first[k] == 0 && cy.incumbentLossCum >= N * _RES[k] / 1e6) cy.first[k] = i + 1;
            }
        }
        cy.attackerNet = int256(m.walA(BOB)) - int256(startBob) - int256(topUp);
        _ledger(m);
    }

    function _logCycle(string memory tag, Prof memory p, uint256 ib, uint256 replBps, Cycle memory c, uint256 reserveBps) internal pure {
        console2.log(
            string.concat(
                "PROTO|CYCLE ", tag, " | ", p.vaultName, " pair ", p.pair, ", deposited ", p.depositedAsset, ", benchmark hold ", p.depositedAsset,
                " | idle paired at start ", vm.toString(ib), " bps, third-party inflow of paired token per cycle ", vm.toString(replBps), " bps of starting value (0 = none) | cycles ", vm.toString(c.cycles),
                " | cumulative incumbent loss (ppm of vault value) ", vm.toString(c.incumbentLossCum * 1e6 / (1000 * p.unit)),
                " | attacker cumulative net (ppm of his stake) ", vm.toString(c.attackerNet * 1e6 / int256(1000 * p.unit / 100)),
                " | first cycle with cumulative loss >= reserve of ", vm.toString(reserveBps), " ppm: ", vm.toString(c.firstExhaust)
            )
        );
    }

    /// Part 3: with replenished idle balances the CURRENT rule re-arms the transfer every cycle and a reserve that pays the
    /// incumbents' loss is drained again and again; under R1/R3 the per-cycle loss is rounding only. Without replenishment
    /// the current rule saturates (the earlier report's observation), which is also asserted.
    function test_30_reserve_drain_current_vs_remedy() public {
        Prof[2] memory ps = [_usdc(), _wavax()];
        uint256[1] memory reserves = [uint256(1_000)]; // 0.1% of vault value (ppm); the full table is test_31
        for (uint256 a; a < 2; ++a) {
            uint256 n = 120;
            // third parties add paired token worth 0.2% of the starting vault value per cycle; the attacker stakes 1% of the vault
            for (uint256 k; k < reserves.length; ++k) {
                Cycle memory cur = _cycleRun(CUR, ps[a], 300, 100, 20, n, reserves[k]);
                Cycle memory r1 = _cycleRun(R1, ps[a], 300, 100, 20, n, reserves[k]);
                Cycle memory r3 = _cycleRun(R3, ps[a], 300, 100, 20, n, reserves[k]);
                _logCycle("CURRENT", ps[a], 300, 20, cur, reserves[k]);
                _logCycle("R1", ps[a], 300, 20, r1, reserves[k]);
                _logCycle("R3", ps[a], 300, 20, r3, reserves[k]);
                if (k == 0) {
                    assertGt(cur.firstExhaust, 0, "current rule: the reserve (0.1%) must be exhausted within the run");
                    assertGt(cur.attackerNet, 0, "current rule: the cycling newcomer profits");
                }
                assertEq(r1.firstExhaust, 0, "R1: no repeatable drain");
                assertEq(r3.firstExhaust, 0, "R3: no repeatable drain");
                assertLt(r1.attackerNet, 0, "R1: cycling loses money");
                assertLt(r3.attackerNet, 0, "R3: cycling loses money");
                // R1/R3 cumulative incumbent loss over n cycles is bounded by n x the per-deposit rounding bound
                assertLe(r1.incumbentLossCum, r1.boundCum, "R1 cumulative incumbent loss within the summed rounding bounds");
                assertLe(r3.incumbentLossCum, r3.boundCum, "R3 cumulative incumbent loss within the summed rounding bounds");
            }
            // no replenishment, saturation of the current rule: the loss of the last 10 of 60 cycles is below that of the first 10
            Cycle memory first = _cycleRun(CUR, ps[a], 1500, 100, 0, 10, 1);
            Cycle memory all = _cycleRun(CUR, ps[a], 1500, 100, 0, 60, 1);
            assertGt(first.incumbentLossCum, 0);
            _logCycle("CURRENT-no-replenish-10", ps[a], 1500, 0, first, 1);
            _logCycle("CURRENT-no-replenish-60", ps[a], 1500, 0, all, 1);
            assertLt(all.incumbentLossCum - first.incumbentLossCum, first.incumbentLossCum, "no replenishment: saturates");
        }
    }

    /// Table for the doc: cycles until the cumulative incumbent loss (what a reserve would have to pay) reaches a reserve of
    /// 0.1%, 0.5%, 1%, 2%, 5% of the vault's starting value; simulated cycle by cycle (not extrapolated), up to 400 cycles.
    function _t31(Prof memory p) internal {
        uint256[3] memory repl = [uint256(5), 20, 100]; // inflow of idle paired token per cycle: 0.05%, 0.2%, 1% of starting value
        for (uint256 j; j < 3; ++j) {
            Cycle memory c = _cycleRun(CUR, p, 300, 100, repl[j], 400, 1_000_000_000);
            string memory row;
            for (uint256 k; k < 5; ++k) {
                row = string.concat(row, " ", vm.toString(_RES[k] / 100), "bp: ", c.first[k] == 0 ? string(">400") : vm.toString(c.first[k]), ";");
            }
            uint256 capturePpm = c.replenished == 0 ? 0 : c.incumbentLossCum * 1e6 / c.replenished;
            console2.log(string.concat("PROTO|31 CURRENT ", p.vaultName, " (pair ", p.pair, ", deposited ", p.depositedAsset, ", benchmark hold ", p.depositedAsset, ") idle paired inflow ", vm.toString(repl[j]), " bps of starting value per cycle, attacker stake 1% of vault; cycles to exhaust a reserve of:", row, " | over 400 cycles: incumbent loss (what a reserve pays) = ", vm.toString(capturePpm), " ppm of the inflow (h/2 = ", vm.toString(uint256(p.h) * 1e6 / 2e4), " ppm), attacker net ppm of stake ", vm.toString(c.attackerNet * 1e6 / int256(1000 * p.unit / 100))));
            Cycle memory r = _cycleRun(R3, p, 300, 100, repl[j], 400, 1_000_000_000);
            Cycle memory r1 = _cycleRun(R1, p, 300, 100, repl[j], 400, 1_000_000_000);
            console2.log(string.concat("PROTO|31 R1/R3 ", p.vaultName, " (pair ", p.pair, ") same inflow, 400 cycles: cumulative incumbent loss raw units R1 ", vm.toString(r1.incumbentLossCum), " (rounding bound ", vm.toString(r1.boundCum), ") R3 ", vm.toString(r.incumbentLossCum), " (rounding bound ", vm.toString(r.boundCum), "); first cycle reaching 0.1% reserve: R1 ", vm.toString(r1.first[0]), " R3 ", vm.toString(r.first[0]), " (0 = never); attacker net ppm of stake R1 ", vm.toString(r1.attackerNet * 1e6 / int256(1000 * p.unit / 100)), " R3 ", vm.toString(r.attackerNet * 1e6 / int256(1000 * p.unit / 100))));
            assertLe(r1.incumbentLossCum, r1.boundCum);
            assertLe(r.incumbentLossCum, r.boundCum);
            assertEq(r1.first[0], 0);
            assertEq(r.first[0], 0);
            assertGt(c.first[0], 0, "current rule: 0.1% reserve is exhausted within 400 cycles");
        }
    }

    function test_31a_reserve_exhaustion_table_usdc() public { _t31(_usdc()); }
    function test_31b_reserve_exhaustion_table_wavax() public { _t31(_wavax()); }

    // =================================================================================================================
    // 6. (v) conservation, wide randomised sweep (all rules): the ledger residual is zero after every operation
    // =================================================================================================================

    function testFuzz_conservation_and_value_ledger(uint256 seed) public {
        VaultShareModel.Rule[4] memory rs = [CUR, R1, R2, R3];
        Prof memory p = seed % 2 == 0 ? _usdc() : _wavax();
        VaultShareModel.Rule r = rs[(seed >> 1) % 4];
        uint256 ib = (seed >> 8) % 5001;
        uint256 pb = 2500 + (seed >> 24) % 5001;
        VaultShareModel m = _genesis(r, p, ib, pb, 9500 + (seed >> 40) % 1000);
        uint256 steps = 4 + (seed >> 56) % 6;
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 kind = x % 4;
            if (kind <= 1) {
                uint256 D = m.nav(false) * (50 + (x >> 8) % 20000) / 1e4;
                m.faucet(DAVE, D, 0);
                m.deposit(DAVE, D);
            } else if (kind == 2 && m.shares(DAVE) > 1) {
                m.redeemInKind(DAVE, m.shares(DAVE) * (1 + (x >> 8) % 10000) / 10000);
            } else {
                uint256 pp = m.qAP(m.nav(false) * ((x >> 8) % 1000) / 1e4);
                m.faucet(DONOR, 0, pp);
                m.donate(DONOR, 0, pp);
            }
            _ledger(m);
        }
    }
}
