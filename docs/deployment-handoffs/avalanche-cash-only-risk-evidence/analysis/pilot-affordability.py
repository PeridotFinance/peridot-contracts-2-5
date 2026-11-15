#!/usr/bin/env python3
"""Pilot affordability tables for the one-direction cash-only lending pilot (PW30 / PW40) at research caps 1,000 / 5,000 / 10,000 USDC.
Closed form with FULL-CAPACITY borrowers (u = 100%) and accrued interest before the event (30 days at the pilot market's borrow APR 12.0%,
debt +0.986%), LI = 1.08, close factor 50%; cross-checked against the fork measurements (AvalancheCashOnlyTreasuryRepayFork.t.sol). RESEARCH
sizes and PROPOSAL parameters, not approved."""
LI = 1.08; I30 = 0.00986; U = 1.0
def loss_frac_of_cap(cf, fall, interest=I30, u=U):
    d = 1 + interest                      # debt at the event, per unit borrowed
    rho = (1 - fall) / (cf * u * d)       # collateral value / debt value after the shock
    return max(0.0, 1 - rho / LI) * d     # unrecoverable debt per unit of cap
CAPS = (1000, 5000, 10000)
print("### Unrecoverable debt = dedicated protection capital needed (USD), borrowers at 100% capacity, 30 days of interest, response within 30 days")
print("| Candidate / tail gap | per 100,000 of cap | cap 1,000 | cap 5,000 | cap 10,000 |")
print("|---|---|---|---|---|")
for name, cf, falls in (("PW40", 0.40, (0.60, 0.676, 0.75)), ("PW30", 0.30, (0.676, 0.75, 0.80))):
    for f in falls:
        L = loss_frac_of_cap(cf, f)
        print(f"| {name} -{f*100:.1f}% | {L*1e5:,.0f} | " + " | ".join(f"{L*c:,.0f}" for c in CAPS) + " |")
print()
print("### Zero-loss gap with full-capacity borrowers and accrued interest (u = 100%, LI = 1.08)")
for name, cf in (("PW40", 0.40), ("PW30", 0.30)):
    print(f"- {name}: no interest {100*(1-cf*LI):.1f}%; after 30 days of interest (+0.986%) {100*(1-cf*LI*(1+I30)):.1f}%; after 90 days at 12% APR (+2.96%) {100*(1-cf*LI*1.0296):.1f}%")
print()
print("### Capital we must provide per research cap (USD), PW40 vs PW30; supplier money shown separately")
print("| Item | cap 1,000 | cap 5,000 | cap 10,000 | who provides |")
print("|---|---|---|---|---|")
sup = [c/0.8 for c in CAPS]
print("| Supplier USDC supply (cap / 0.8; a 20% cash floor = withdrawal cash) | " + " | ".join(f"{s:,.0f}" for s in sup) + " | suppliers (NOT our capital) |")
print("| of which withdrawal cash held by the floor | " + " | ".join(f"{s*0.2:,.0f}" for s in sup) + " | suppliers' own un-lent cash |")
d = 1 + I30
print("| Liquidator inventory, first round per operator (0.5 x debt incl. interest; minimum IF recycling works, not the requirement) | " + " | ".join(f"{0.5*c*d:,.0f}" for c in CAPS) + " | liquidator operators (capital at work, not spent) |")
print("| **REQUIREMENT per operator, no recycling: at least 0.75 x cap debt** | " + " | ".join(f"{0.75*c:,.0f}" for c in CAPS) + " | each liquidator operator (capital at work, recovered, not spent) |")
print("| **about 0.88 x in a 30-day outage tail (incl. interest)** | " + " | ".join(f"{0.88*c*d:,.0f}" for c in CAPS) + " | each liquidator operator |")
for name, cf, f in (("PW40", 0.40, 0.60), ("PW40", 0.40, 0.75), ("PW30", 0.30, 0.75), ("PW30", 0.30, 0.80)):
    L = loss_frac_of_cap(cf, f)
    print(f"| Protection capital {name}, tail -{f*100:.0f}% | " + " | ".join(f"{L*c:,.0f}" for c in CAPS) + " | the operator (treasury, not yet committed) |")
print("| Operating cost: gas per liquidation (244k-390k gas, 2.5 gwei, AVAX 8.43) | 0.005-0.008 | 0.005-0.008 | 0.005-0.008 | operator |")
print("| Operating cost: monitoring (batched reads), hosting, alerts | reused / cents | reused / cents | reused / cents | operator (no subscription proposed) |")
