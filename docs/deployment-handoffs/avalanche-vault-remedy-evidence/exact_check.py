#!/usr/bin/env python3
"""Exact-rational (fractions.Fraction, no rounding anywhere) check of the share-pricing algebra. TEST-ONLY MODEL, not vault code.

State: real holdings H (oracle value), of which P is the paired token (oracle value); supply S; haircut h (fraction).
A deposit adds a contribution K (oracle value Hk, paired part Pk, Pk may be negative: the vault sold incumbents' idle paired token).
  CURRENT : mint on haircut NAV   N = H - h P          m = S (N1 - N0) / N0
  R1      : mint on ownership NAV N = H                m = S (N1 - N0) / N0
  R2      : CURRENT mint, but Pk/Hk = P0/H0 (deployment in the vault's own composition), swap cost c on the swapped asset x
Newcomer in-kind entitlement value = H1 m / (S + m); transfer T = that - Hk; incumbent change = -T (value ledger, exact).
"""
import random
from fractions import Fraction as F

random.seed(20261103)

def transfer(rule, H0, P0, S, Hk, Pk, h):
    H1, P1 = H0 + Hk, P0 + Pk
    if rule == "CURRENT":
        N0, N1 = H0 - h * P0, H1 - h * P1
    else:
        N0, N1 = H0, H1
    m = S * (N1 - N0) / N0
    return H1 * m / (S + m) - Hk

def closed_form(H0, P0, Hk, Pk, h):
    H1, P1 = H0 + Hk, P0 + Pk
    return h * (Hk * P1 - Pk * H1) / (H1 - h * P1)

n = 0
worst_r1 = F(0)
neg = 0
for _ in range(20000):
    H0 = F(random.randint(500, 5_000_000))
    P0 = H0 * F(random.randint(0, 9000), 10000)
    S = F(random.randint(500, 9_000_000))
    h = F(random.choice([100, 300, 1000, 2000]), 10000)
    Hk = H0 * F(random.randint(1, 30000), 10000)           # 0.01% .. 300% of the vault
    Pk = Hk * F(random.randint(-9000, 9000), 10000)        # contribution composition independent of the vault's (may be negative)
    t = transfer("CURRENT", H0, P0, S, Hk, Pk, h)
    assert t == closed_form(H0, P0, Hk, Pk, h), "closed form is an exact identity"
    assert transfer("R1", H0, P0, S, Hk, Pk, h) == 0, "R1: transfer exactly 0 for every state"
    if t < 0: neg += 1
    # R2: contribution in the vault's own composition up to a swap cost c on the swapped asset x = D*rho
    D = Hk
    rho = P0 / H0
    c = F(random.randint(-20, 60), 10000)
    x = D * rho
    Hk2, Pk2 = D - c * x, x * (1 - c)
    t2 = transfer("CURRENT", H0, P0, S, Hk2, Pk2, h)
    H1, P1 = H0 + Hk2, P0 + Pk2
    assert t2 == h * (c * x) * (H0 - P0) / (H1 - h * P1), "R2 residual = h costVal A0 / (H1 - h P1)"
    if c == 0: assert t2 == 0
    n += 1
print(f"exact check OK: {n} random states, closed form == CURRENT-rule transfer (identity), R1 transfer == 0 exactly, R2 residual == h*costVal*A0/(H1-h*P1) exactly; {neg} states had T < 0 (incumbent gains)")

# Part 3 steady state: an attacker deposits D small (< idle paired value I), exits in kind, repeating while an external flow
# keeps adding idle paired value.  The vault sells (I - D)/2 of idle paired for the asset ("sell regime"): K has Pk = -(I-D)/2.
def sell_regime(H0, I, D, S, h):
    # K: asset +D, then swap y = (I - D)/2 of paired value into asset at the oracle (cost 0): Hk = D, Pk = -y
    y = (I - D) / 2
    P0 = I + (H0 - I) / 2          # paired share of the position taken as 50% of non-idle value (illustrative)
    return transfer("CURRENT", H0, P0, S, D, -y, h), y
for h in (F(1, 100), F(3, 100)):
    H0, S = F(1_000_000), F(1_000_000)
    for ifrac in (F(1, 100), F(3, 100), F(15, 100)):
        I = H0 * ifrac
        D = H0 / 1000
        t, y = sell_regime(H0, I, D, S, h)
        print(f"h={float(h):.2f} idle={float(ifrac):.2f}: exact T = {float(t):.2f} ({float(t / H0 * 1e6):.0f} ppm of vault) ; h*y = {float(h * y):.2f}  (T / (h*y) = {float(t / (h * y)):.4f})")
