#!/usr/bin/env python3
"""Cash-only lending decision table: candidate configurations derived from the closed form of the stress tests
(avalanche-cash-only-risk-proposal.md section 2.1; fork suite AvalancheCashOnlyRiskStudyFork.t.sol) and empirical gap sizes.
Usage: python3 decision-table.py   (prints markdown). Inputs: ../price-data/*.json. PROPOSALS ONLY, no approved parameters."""
import json, os, datetime
HERE = os.path.dirname(os.path.abspath(__file__)); PD = os.path.join(HERE, "..", "price-data")
LI, U = 1.08, 0.99          # liquidation incentive; borrower utilisation of borrowing power (99% = maximum allowed borrow)
def load(f): return [(t/1000, p) for t, p in json.load(open(os.path.join(PD, f)))["prices"]]
d, h = load("avalanche-2-365.json"), load("avax-90h.json")

def worst(series, steps):
    return (min(series[i+steps][1]/series[i][1]-1 for i in range(len(series)-steps)),
            max(series[i+steps][1]/series[i][1]-1 for i in range(len(series)-steps)))
WINDOWS = [("1 h", h, 1), ("6 h", h, 6), ("24 h", h, 24), ("3 days", d, 3), ("7 days", d, 7), ("14 days", d, 14), ("30 days", d, 30)]
emp = {lab: worst(s, n) for lab, s, n in WINDOWS}
peak = d[0][1]; mdd = 0
for _, p in d: peak = max(peak, p); mdd = min(mdd, p/peak-1)
trough = d[0][1]; mru = 0
for _, p in d: trough = min(trough, p); mru = max(mru, p/trough-1)

def loss_W(cf, fall, u=U):      # USDC debt vs WAVAX collateral, AVAX falls by `fall`
    rho = (1-fall)/(cf*u); return max(0.0, 1 - rho/LI)
def loss_U(cf, rise, u=U):      # WAVAX debt vs USDC collateral, AVAX rises by `rise`
    rho = 1/(cf*u*(1+rise)); return max(0.0, 1 - rho/LI)
def gap_W(cf, u=U): return 1 - cf*u*LI
def gap_U(cf, u=U): return 1/(cf*u*LI) - 1
def cf_W(fall, u=U): return (1-fall)/(u*LI)
def cf_U(rise, u=U): return 1/(u*LI*(1+rise))

print("## A. Empirical AVAX/USD moves by window (source: price-data/README.md)")
print("| Window (= length of an outage or of a liquidation delay) | worst fall | worst rise | largest CF with zero bad debt: W (USDC debt) at that fall | U (WAVAX debt) at that rise |")
print("|---|---|---|---|---|")
for lab, _, _ in WINDOWS:
    f, r = emp[lab]
    print(f"| {lab} | {f*100:.1f}% | +{r*100:.1f}% | {cf_W(-f)*100:.1f}% | {cf_U(r)*100:.1f}% |")
print(f"| peak-to-trough over the year (daily closes) | {mdd*100:.1f}% | trough-to-peak +{mru*100:.1f}% | {cf_W(-mdd)*100:.1f}% | {cf_U(mru)*100:.1f}% |")
print()
CANDS = [("PW30", 0.30, 0.0, "pilot, one direction"), ("PW40", 0.40, 0.0, "pilot, one direction"), ("PW50", 0.50, 0.0, "pilot, one direction"),
         ("D40/40", 0.40, 0.40, "two directions"), ("D50/50", 0.50, 0.50, "two directions"), ("D60/60", 0.60, 0.60, "two directions"),
         ("PLACEHOLDER 60/75", 0.60, 0.75, "two directions (test placeholder)")]
print("## B. Zero-bad-debt gap and loss beyond it (u = 99%, LI = 1.08; % of the debt of the affected direction)")
print("| Candidate | CF W | CF U | W zero-loss fall | loss at -50% / -60% / -67.6% (year drawdown) / -75% | U zero-loss rise | loss at +100% / +150% / +200% |")
print("|---|---|---|---|---|---|---|")
for n, cw, cu, _ in CANDS:
    w = " / ".join(f"{loss_W(cw, x)*100:.1f}%" for x in (0.5, 0.6, -mdd, 0.75))
    if cu == 0:
        uu, ul = "n/a (direction disabled)", "n/a"
    else:
        uu = f"+{gap_U(cu)*100:.0f}%"; ul = " / ".join(f"{loss_U(cu, x)*100:.1f}%" for x in (1.0, 1.5, 2.0))
    print(f"| {n} | {cw*100:.0f}% | {cu*100:.0f}% | -{gap_W(cw)*100:.1f}% | {w} | {uu} | {ul} |")
print()
print("## C. Which empirical windows each candidate survives with zero bad debt (u = 99%)")
print("| Candidate | W survives worst move of: | U survives worst move of: |")
print("|---|---|---|")
def wins(gapf, cf, side):
    ok = []
    for lab, _, _ in WINDOWS:
        f, r = emp[lab]; g = -f if side == "W" else r
        if (gapf(cf) >= g): ok.append(lab)
    if side == "W" and gapf(cf) >= -mdd: ok.append("year drawdown")
    if side == "U" and gapf(cf) >= mru: ok.append("year run-up")
    return ", ".join(ok) if ok else "none"
for n, cw, cu, _ in CANDS:
    print(f"| {n} | {wins(gap_W, cw, 'W')} | {'n/a' if cu == 0 else wins(gap_U, cu, 'U')} |")
print()
print("## D. Dedicated protection capital per USD 100,000 of borrow cap (loss at a stated tail gap; zero where the candidate survives it)")
print("| Candidate | W tail -60% | W tail -67.6% | W tail -75% | U tail +100% | U tail +150% |")
print("|---|---|---|---|---|---|")
for n, cw, cu, _ in CANDS:
    row = [f"{loss_W(cw, x)*1e5:,.0f}" for x in (0.6, -mdd, 0.75)]
    row += ["n/a", "n/a"] if cu == 0 else [f"{loss_U(cu, x)*1e5:,.0f}" for x in (1.0, 1.5)]
    print(f"| {n} | " + " | ".join(row) + " |")
print("(USD per 100,000 of debt cap in that direction; two-direction candidates need both directions' protection if both caps are used.)")
print()
print("## E. Cap that a given protection capital supports (USD of borrow cap per USD 10,000 of protection capital) at a stated tail gap")
print("| Candidate | W tail -67.6% | W tail -75% | U tail +100% |")
print("|---|---|---|---|")
for n, cw, cu, _ in CANDS:
    def cap(l): return "unbounded (zero loss)" if l <= 1e-12 else f"{1e4/l:,.0f}"
    print(f"| {n} | {cap(loss_W(cw, -mdd))} | {cap(loss_W(cw, 0.75))} | {'n/a' if cu == 0 else cap(loss_U(cu, 1.0))} |")
print()
print("## F. Gradual-path bad debt (measured, risk study section 2.4; share of debt at 99% utilisation, steps of 5/10/20% for W, 10/25/50% for U; K = liquidation calls per account per step)")
print("| CF | W K=1 | W K=4 | U K=1 | U K=4 |")
print("|---|---|---|---|---|")
for cf, a, b, c_, d_ in [(30, "0/0/0", "0/0/0", "0/0/0", "0/0/0"), (50, "0/0/1.8%", "0/0/0", "0/0/1.9%", "0/0/0"), (60, "0/0.3%/8.4%", "0/0/1.1%", "0/0/12.6%", "0/0/0"), (70, "0/0.9%/13.2%", "0/0/0.7%", "0/6.6%/21.6%", "0/0/10.9%")]:
    print(f"| {cf}% | {a} | {b} | {c_} | {d_} |")
print("(40% was not in the gradual-path grid; between the 30% and 50% rows.)")
