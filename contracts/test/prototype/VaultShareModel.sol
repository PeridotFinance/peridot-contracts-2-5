// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultShareModel
/// @notice TEST-ONLY MODEL. Not deployable code, does not import, inherit or call the Pharaoh vault.
///         It reproduces, with the same integer arithmetic (OpenZeppelin Math.mulDiv, floors, the `+1`
///         virtual offsets of ERC-4626), the share accounting of PharaohLiquidityVault
///         (verified source sha256 fb951b92..., lines cited as `V:<n>`) against an abstract pool and oracle:
///           * totalAssets            V:210-220   haircut NAV: idle + principal, paired token valued at oracle x (1 - h)
///           * _executeDeposit        V:382-407   mint = mulDiv(valueAfter - valueBefore, supply + 1, valueBefore + 1)
///           * _balanceIdle           V:494-515   50/50 split of ALL idle (including incumbents' idle paired token)
///           * _addLiquidity          V:517-581   deploy at the position's own ratio, remainder stays idle
///           * redeemInKind           V:353-380   pro rata idle + floor(liquidity x shares / supply)
///           * redeem (cash)          V:318-346   pays floor(shares x (V + 1) / (supply + 1)) at the HAIRCUT NAV
///         Four rules are modelled (`Rule`): CURRENT (the deployed rule) and the candidate remedies R1, R2, R3, plus two
///         MUTATIONS (deliberately wrong versions of R1, used to show that the remedy tests can fail).
/// @dev Units: raw integers. `qWad` = asset raw units per ONE paired raw unit, scaled 1e18 (the oracle price).
///      The pool executes at `qWad x (1e6 + betaPpm) / 1e6` with a proportional fee and a linear price impact
///      `impact = valueIn / depth` (parts per 1e6). Nothing here is an estimate of the real pools; the real pools are
///      replayed by AvalancheVaultShareCheckFork.t.sol.
contract VaultShareModel {
    enum Rule {
        CURRENT, // deployed: mint on haircut NAV delta, 50/50 balance of all idle
        R1, // ownership NAV (no haircut) delta for the mint; deployment unchanged
        R2, // mint unchanged (haircut NAV delta); deployment splits the NEW asset in the vault's own composition
        R3, // R1 + R2
        MUT_ASYM_NET, // MUTATION of R1: haircut charged on the paired leg the newcomer adds, not on the vault
        MUT_DENOM_HAIRCUT // MUTATION of R1: net contribution at ownership, denominator at haircut NAV
    }

    enum CashMode {
        HAIRCUT, // deployed `redeem`: pays the haircut NAV, the difference stays in the vault
        REALIZED // candidate: exiter's own pro-rata slice, his paired leg sold at his own cost, haircut NAV is a guard
    }

    Rule public immutable rule;
    uint256 public immutable qWad;
    uint16 public immutable hBps;
    uint16 public immutable slipBps;
    uint256 public immutable feePpm;
    int256 public immutable betaPpm;
    uint256 public immutable depth;

    // valuation position vs real position (models "TWAP tick != spot tick"): bps of the position's asset
    // (positive) or paired (negative) value that the valuation sees on the other side of the pair.
    int256 public valSkewBps;
    /// @dev A tick other than spot moves amounts between the two tokens at the POOL price, so at the oracle price the
    ///      valued position is worth `VAL_GAP_BPS` more (skew > 0) or less (skew < 0) on the moved value.
    uint256 public constant VAL_GAP_BPS = 10;

    // vault state
    uint256 public idleA;
    uint256 public idleP;
    uint256 public posA;
    uint256 public posP;
    uint256 public liq;
    uint256 public supply;
    mapping(address => uint256) public shares;

    // wallets and ledger
    mapping(address => uint256) public walA;
    mapping(address => uint256) public walP;
    address[] public actors;
    mapping(address => bool) private isActor;
    uint256 public issuedA;
    uint256 public issuedP;
    int256 public poolNetA; // tokens the pool received minus tokens it paid out
    int256 public poolNetP;

    constructor(Rule r, uint256 q, uint16 h, uint16 slip, uint256 fee, int256 beta, uint256 d) {
        rule = r;
        qWad = q;
        hBps = h;
        slipBps = slip;
        feePpm = fee;
        betaPpm = beta;
        depth = d;
    }

    function setValuationSkew(int256 s) external {
        valSkewBps = s;
    }

    // ------------------------------------------------------------------ ledger / genesis
    function _actor(address a) internal {
        if (!isActor[a]) {
            isActor[a] = true;
            actors.push(a);
        }
    }

    function faucet(address to, uint256 a, uint256 p) external {
        _actor(to);
        walA[to] += a;
        walP[to] += p;
        issuedA += a;
        issuedP += p;
    }

    /// @dev Direct state construction (a vault that already holds the stated inventory and shares).
    function genesis(
        uint256 iA,
        uint256 iP,
        uint256 pA,
        uint256 pP,
        uint256 liquidity,
        address[] calldata holders,
        uint256[] calldata amounts
    ) external {
        require(supply == 0, "genesis once");
        idleA = iA;
        idleP = iP;
        posA = pA;
        posP = pP;
        liq = liquidity;
        issuedA += iA + pA;
        issuedP += iP + pP;
        uint256 s;
        for (uint256 i; i < holders.length; ++i) {
            _actor(holders[i]);
            shares[holders[i]] = amounts[i];
            s += amounts[i];
        }
        supply = s;
    }

    function ledgerResidualA() public view returns (int256) {
        uint256 w;
        for (uint256 i; i < actors.length; ++i) {
            w += walA[actors[i]];
        }
        return int256(w + idleA + posA) + poolNetA - int256(issuedA);
    }

    function ledgerResidualP() public view returns (int256) {
        uint256 w;
        for (uint256 i; i < actors.length; ++i) {
            w += walP[actors[i]];
        }
        return int256(w + idleP + posP) + poolNetP - int256(issuedP);
    }

    // ------------------------------------------------------------------ oracle and valuation
    function qPA(uint256 p) public view returns (uint256) {
        return Math.mulDiv(p, qWad, 1e18);
    }

    function qAP(uint256 a) public view returns (uint256) {
        return Math.mulDiv(a, 1e18, qWad);
    }

    function _valPos() internal view returns (uint256 pa, uint256 pp) {
        pa = posA;
        pp = posP;
        int256 s = valSkewBps;
        if (s > 0) {
            uint256 mv = Math.mulDiv(posA, uint256(s), 1e4);
            pa -= mv;
            pp += Math.mulDiv(qAP(mv), 1e4 + VAL_GAP_BPS, 1e4);
        } else if (s < 0) {
            uint256 mv = Math.mulDiv(posP, uint256(-s), 1e4);
            pp -= mv;
            pa += Math.mulDiv(qPA(mv), 1e4 - VAL_GAP_BPS, 1e4);
        }
    }

    /// @dev V:210-220. haircut=true is totalAssets(); false is the ownership value (same split, no haircut).
    function nav(bool haircut) public view returns (uint256) {
        (uint256 pa, uint256 pp) = _valPos();
        uint256 a = idleA + pa;
        uint256 p = idleP + pp;
        if (p == 0) return a;
        uint256 pv = qPA(p);
        if (haircut) pv = Math.mulDiv(pv, 1e4 - hBps, 1e4);
        return a + pv;
    }

    function totalAssets() external view returns (uint256) {
        return nav(true);
    }

    /// @dev Real holdings (idle + position) at the REAL position vector (what in-kind redemption pays).
    function holdings() public view returns (uint256 a, uint256 p) {
        return (idleA + posA, idleP + posP);
    }

    function holdingsValue() public view returns (uint256) {
        (uint256 a, uint256 p) = holdings();
        return a + qPA(p);
    }

    function _mintBasisHaircut() internal view returns (bool) {
        return rule == Rule.CURRENT || rule == Rule.R2;
    }

    // ------------------------------------------------------------------ pool
    function _impact(uint256 value) internal view returns (uint256 imp) {
        imp = Math.mulDiv(value, 1e6, depth);
        if (imp > 500_000) imp = 500_000;
    }

    function _poolQ() internal view returns (uint256) {
        return uint256(int256(qWad) * (1e6 + betaPpm) / 1e6);
    }

    function _swapAP(uint256 inA) internal returns (uint256 out) {
        uint256 imp = _impact(inA);
        uint256 net = Math.mulDiv(inA, 1e6 - feePpm, 1e6);
        net = Math.mulDiv(net, 1e6 - imp, 1e6);
        out = Math.mulDiv(net, 1e18, _poolQ());
        idleA -= inA;
        idleP += out;
        poolNetA += int256(inA);
        poolNetP -= int256(out);
    }

    function _swapPA(uint256 inP) internal returns (uint256 out) {
        out = _quotePA(inP);
        idleP -= inP;
        idleA += out;
        poolNetP += int256(inP);
        poolNetA -= int256(out);
    }

    function _quotePA(uint256 inP) internal view returns (uint256 out) {
        uint256 gross = Math.mulDiv(inP, _poolQ(), 1e18);
        uint256 imp = _impact(gross);
        out = Math.mulDiv(gross, 1e6 - feePpm, 1e6);
        out = Math.mulDiv(out, 1e6 - imp, 1e6);
    }

    /// @notice An outsider (the cycling newcomer) sells paired token through the pool from his wallet.
    function walletSellPaired(address who, uint256 inP) external returns (uint256 out) {
        require(walP[who] >= inP, "bal");
        out = _quotePA(inP);
        walP[who] -= inP;
        walA[who] += out;
        poolNetP += int256(inP);
        poolNetA -= int256(out);
    }

    // ------------------------------------------------------------------ replenishment of idle balances
    /// @notice A third party (or collected fees) adds tokens to the vault's idle balance without receiving shares.
    function donate(address from, uint256 a, uint256 p) external {
        require(walA[from] >= a && walP[from] >= p, "bal");
        walA[from] -= a;
        walP[from] -= p;
        idleA += a;
        idleP += p;
    }

    /// @notice Keeper `deployIdle` (V:417-422): balance idle 50/50 by oracle value and add liquidity. Cost is borne pro rata.
    function keeperDeployIdle() external {
        _balanceIdle();
        _addLiquidity();
    }

    // ------------------------------------------------------------------ deployment (V:489-581)
    function _balanceIdle() internal {
        uint256 assetBalance = idleA;
        uint256 pairBalance = idleP;
        uint256 pairValue = qPA(pairBalance);
        if (assetBalance > pairValue + 1) {
            uint256 amountIn = (assetBalance - pairValue) / 2;
            if (amountIn > 0) _swapAP(amountIn);
        } else if (pairValue > assetBalance + 1) {
            uint256 valueToSwap = (pairValue - assetBalance) / 2;
            uint256 amountIn = qAP(valueToSwap);
            if (amountIn > pairBalance) amountIn = pairBalance;
            if (amountIn > 0) _swapPA(amountIn);
        }
    }

    function _addLiquidity() internal {
        if (idleA == 0 && idleP == 0) return;
        require(liq != 0 && posA != 0 && posP != 0, "model: two-sided position required");
        uint256 byA = Math.mulDiv(idleA, liq, posA);
        uint256 byP = Math.mulDiv(idleP, liq, posP);
        uint256 add = byA < byP ? byA : byP;
        if (add == 0) return;
        uint256 cA = Math.mulDiv(posA, add, liq, Math.Rounding.Ceil);
        uint256 cP = Math.mulDiv(posP, add, liq, Math.Rounding.Ceil);
        idleA -= cA;
        idleP -= cP;
        posA += cA;
        posP += cP;
        liq += add;
    }

    // ------------------------------------------------------------------ deposit (V:277-292, 382-407)
    function _mintNavs() internal view returns (uint256) {
        return nav(_mintBasisHaircut());
    }

    function deposit(address who, uint256 assets) external returns (uint256 minted) {
        require(assets != 0, "zero");
        require(walA[who] >= assets, "bal");
        uint256 own0 = nav(false);
        uint256 hair0 = nav(true);
        uint256 pv0 = qPA(idleP + _valPos2());
        uint256 valueBefore;
        if (rule == Rule.CURRENT || rule == Rule.R2) valueBefore = hair0;
        else valueBefore = own0;
        uint256 denomBefore = rule == Rule.MUT_DENOM_HAIRCUT ? hair0 : valueBefore;

        walA[who] -= assets;
        idleA += assets;
        if (rule == Rule.R2 || rule == Rule.R3) {
            if (own0 == 0 || pv0 == 0) {
                _balanceIdle();
            } else {
                uint256 amountIn = Math.mulDiv(assets, pv0, own0);
                if (amountIn > 0) _swapAP(amountIn);
            }
        } else {
            _balanceIdle();
        }
        _addLiquidity();

        uint256 valueAfter = (rule == Rule.CURRENT || rule == Rule.R2) ? nav(true) : nav(false);
        require(valueAfter > valueBefore, "no contribution");
        uint256 net = valueAfter - valueBefore;
        if (rule == Rule.MUT_ASYM_NET) {
            uint256 pv1 = qPA(idleP + _valPos2());
            if (pv1 > pv0) {
                uint256 pen = Math.mulDiv(pv1 - pv0, hBps, 1e4);
                net = net > pen ? net - pen : 0;
            }
        }
        minted = Math.mulDiv(net, supply + 1, denomBefore + 1);
        shares[who] += minted;
        supply += minted;
        _actor(who);
    }

    function _valPos2() internal view returns (uint256 pp) {
        (, pp) = _valPos();
    }

    // ------------------------------------------------------------------ exits
    /// @notice V:353-380.
    function redeemInKind(address who, uint256 sh) external returns (uint256 a, uint256 p) {
        require(sh != 0 && shares[who] >= sh, "shares");
        (a, p) = _entitlement(sh);
        uint256 S = supply;
        uint256 iA = Math.mulDiv(idleA, sh, S);
        uint256 iP = Math.mulDiv(idleP, sh, S);
        uint256 lr = sh == S ? liq : Math.mulDiv(liq, sh, S);
        uint256 oA;
        uint256 oP;
        if (lr > 0) {
            oA = lr == liq ? posA : Math.mulDiv(posA, lr, liq);
            oP = lr == liq ? posP : Math.mulDiv(posP, lr, liq);
            posA -= oA;
            posP -= oP;
            liq -= lr;
        }
        idleA -= iA;
        idleP -= iP;
        shares[who] -= sh;
        supply = S - sh;
        walA[who] += iA + oA;
        walP[who] += iP + oP;
        _actor(who);
    }

    function _entitlement(uint256 sh) internal view returns (uint256 a, uint256 p) {
        uint256 S = supply;
        a = Math.mulDiv(idleA, sh, S);
        p = Math.mulDiv(idleP, sh, S);
        uint256 lr = sh == S ? liq : Math.mulDiv(liq, sh, S);
        if (lr > 0) {
            a += lr == liq ? posA : Math.mulDiv(posA, lr, liq);
            p += lr == liq ? posP : Math.mulDiv(posP, lr, liq);
        }
    }

    /// @notice What `redeemInKind` of `who`'s whole balance would pay now (no state change).
    function entitlementOf(address who) public view returns (uint256 a, uint256 p) {
        uint256 sh = shares[who];
        if (sh == 0) return (0, 0);
        return _entitlement(sh);
    }

    function entitlementValue(address who) public view returns (uint256) {
        (uint256 a, uint256 p) = entitlementOf(who);
        return a + qPA(p);
    }

    /// @notice Cash exit. HAIRCUT is the deployed `redeem` (V:318-346); REALIZED is a candidate (see the remedy doc).
    function redeemCash(address who, uint256 sh, CashMode mode) external returns (uint256 paid) {
        require(sh != 0 && shares[who] >= sh, "shares");
        uint256 S = supply;
        uint256 guard = Math.mulDiv(sh, nav(true) + 1, S + 1);
        if (mode == CashMode.HAIRCUT) {
            uint256 assets = guard;
            shares[who] -= sh;
            supply = S - sh;
            uint256 lr = sh == S ? liq : Math.mulDiv(liq, sh, S, Math.Rounding.Ceil);
            if (lr > liq) lr = liq;
            if (lr > 0) {
                uint256 oA = lr == liq ? posA : Math.mulDiv(posA, lr, liq);
                uint256 oP = lr == liq ? posP : Math.mulDiv(posP, lr, liq);
                posA -= oA;
                posP -= oP;
                liq -= lr;
                idleA += oA;
                idleP += oP;
            }
            if (sh == S) {
                if (idleP > 0) _swapPA(idleP);
                assets = idleA;
            } else if (idleA < assets) {
                uint256 shortfall = assets - idleA;
                uint256 pairIn = Math.mulDiv(qAP(shortfall), 1e4, 1e4 - slipBps, Math.Rounding.Ceil);
                if (pairIn > idleP) pairIn = idleP;
                require(pairIn > 0, "insufficient");
                _swapPA(pairIn);
                require(idleA >= assets, "insufficient after swap");
            }
            idleA -= assets;
            walA[who] += assets;
            paid = assets;
        } else {
            (uint256 a, uint256 p) = _entitlement(sh);
            uint256 lr = sh == S ? liq : Math.mulDiv(liq, sh, S);
            uint256 iA = Math.mulDiv(idleA, sh, S);
            uint256 iP = Math.mulDiv(idleP, sh, S);
            uint256 oA;
            uint256 oP;
            if (lr > 0) {
                oA = lr == liq ? posA : Math.mulDiv(posA, lr, liq);
                oP = lr == liq ? posP : Math.mulDiv(posP, lr, liq);
                posA -= oA;
                posP -= oP;
                liq -= lr;
            }
            idleA -= iA;
            idleP -= iP;
            shares[who] -= sh;
            supply = S - sh;
            require(a == iA + oA && p == iP + oP, "slice");
            // sell his paired slice at his own cost
            uint256 got = _quotePA(p);
            poolNetP += int256(p);
            poolNetA -= int256(got);
            paid = a + got;
            require(paid >= guard, "below haircut guard");
            walA[who] += paid;
        }
        _actor(who);
    }
}
