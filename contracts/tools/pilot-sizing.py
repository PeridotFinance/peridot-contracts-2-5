#!/usr/bin/env python3
"""ONE INPUT SIZING of the whole Avalanche pilot (lending PW30, vaults, margin 2x, operators).

Everything is linear in one number, CAP (USD): the USDC borrow cap of the lending market. Ratios (operator decision of 9 Nov 2026):
  supply 1.25 x CAP, each operator 0.89 x CAP, treasury 0.24 x CAP, flash vault 0.5 x CAP, insurance 5% of CAP,
  per-call liquidation cap 0.3 x CAP, daily cap 0.5 x CAP per operator, seeds minimal.
Same contracts, same PW30 parameters (rates, factors, close factor, incentive). Caps are raised later by a parameter change; nothing here is
a measurement, it is arithmetic on CAP and on the AVAX price (for the WAVAX amounts).

Usage:
  python3 tools/pilot-sizing.py --cap-usd 1000 --avax-usd 7.83 [--gas-gwei 2.5] [--write]
Without --write it only prints the table. With --write it (re)writes contracts/ceremony/pilot-pw30.env, contracts/ceremony/margin-sizing.env,
contracts/ceremony/pilot-sizing.json (the values the host configurations take) and docs/deployment-handoffs/avalanche-pilot-sizing-table.md.
Public values only. No key, no endpoint.
"""
import argparse
import json
import os
import sys
from decimal import Decimal as D, ROUND_CEILING, ROUND_FLOOR

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # contracts/
REPO = os.path.dirname(ROOT)

# ---- ratios (of CAP)
R = dict(
    supply=D("1.25"), operator=D("0.89"), treasury=D("0.24"), flash=D("0.5"), insurance=D("0.05"),
    per_call=D("0.3"), daily=D("0.5"), cash_floor_of_supply=D("0.2"), team_borrow_rule=D("0.4"),
    margin_position=D("1"), margin_debt=D("0.5"), operator_inventory_min=D("0.75"),
    wavax_borrow_cap_value=D("0.2"),  # WAVAX borrowing stays PAUSED: this cap only bounds a mistake
)
SEED_FRAC_LENDING = D("0.02")  # each lending market seed (held by the market forever); the 2% of the research size is USD 100 at 5,000
SEED_FRAC_VAULT = D("0.05")  # team seed into each Pharaoh vault (counts against its cap); proposal "minimal", the research size was 10%
SEED_FLOOR_USD = D("10")  # below this the seed no longer protects the first share price against donation / rounding games
CAP_MIN, CAP_MAX = D("100"), D("5000")

# gas, measured in the rehearsal broadcasts (see docs): units of gas USED
GAS = dict(
    margin_deployer=31_908_928,   # 22 transactions, stage 1, throwaway deployer
    pw30_ledger=19_986_502,       # 30 transactions, the PW30 ceremony (the Ledger is the deployer)
    margin_ledger=1_526_433 + 198_890 + 46_095,  # 24 + 3 + 1 transactions
    vaults_ledger=12_000_000,     # caps (2), team seed approve/deposit/deployIdle (6): the deposits use about 2.4M each, estimate with margin
    r3_ledger=9_000_000,          # base 5.4M + extension 0.6M + 2 upgradeAndCall + 2 setRebalancer, estimate with margin
)


def q(x, places=6, mode=ROUND_CEILING):
    return x.quantize(D(1).scaleb(-places), rounding=mode)


def units(usd, decimals=6):
    return int((usd * D(10) ** decimals).to_integral_value(rounding=ROUND_FLOOR))


def sizing(cap, avax, gwei):
    s = {}
    seed_usd = max(SEED_FLOOR_USD, cap * SEED_FRAC_LENDING)
    vseed_usd = max(SEED_FLOOR_USD, cap * SEED_FRAC_VAULT)
    supply = cap * R["supply"]
    s["cap_usd"] = cap
    s["avax_usd"] = avax
    # --- USDC
    s["usdc"] = dict(
        borrow_cap=cap, market_seed=seed_usd, team_supply=supply, flash_vault=cap * R["flash"], insurance=cap * R["insurance"],
        vault_team_seed=vseed_usd, operator_each=cap * R["operator"], treasury=cap * R["treasury"],
        cash_floor=supply * R["cash_floor_of_supply"], team_borrow_rule=cap * R["team_borrow_rule"],
    )
    # --- WAVAX (amounts follow the price; the CAPS in WAVAX move in dollars with it, as for the vaults)
    s["wavax"] = dict(
        market_seed=seed_usd / avax, vault_team_seed=vseed_usd / avax, vault_cap=cap / avax, wavax_borrow_cap=cap * R["wavax_borrow_cap_value"] / avax,
    )
    # --- margin
    s["margin"] = dict(position_cap=cap * R["margin_position"], debt_cap=cap * R["margin_debt"])
    # --- operators' software caps (integers of USD for the configuration)
    def ui(x):
        return max(1, int(x.to_integral_value(rounding=ROUND_FLOOR)))
    s["operator_config"] = dict(
        usdcBorrowCapUsd=ui(cap), protectionCapitalUsd=ui(cap * R["treasury"]), operatorInventoryMinUsd=ui(cap * R["operator_inventory_min"]),
        operatorInventoryTargetUsd=ui(cap * R["operator"]), cashFloorBp=2000,
        keeperDailySpendCapUsdc=ui(cap * R["treasury"]), marginDailyRepayCapUsdc=ui(cap * R["daily"]), marginMaxRepayPerCallUsdc=ui(cap * R["per_call"]),
    )
    # --- AVAX. Gas price is the live fee; the amounts are "measured gas used x price x 1.5" for one-shot signers, and a small float for the processes.
    price = gwei * D(10) ** -9  # AVAX per gas
    def avax_for(gas):
        return q(D(gas) * price * D("1.5"), 4)
    s["avax"] = dict(
        gas_gwei=gwei,
        deployer=avax_for(GAS["margin_deployer"]),
        ledger_total=avax_for(GAS["pw30_ledger"] + GAS["vaults_ledger"] + GAS["r3_ledger"] + GAS["margin_ledger"]),
        ledger_pw30=avax_for(GAS["pw30_ledger"]),
        operator_each=D("0.1"), keeper=D("0.1"), rebalancer=D("0.1"), process_floor=D("0.04"),  # host wallets 0.1 AVAX each (operator decision 9 Nov); alert floor 0.04 AVAX ~ 16M gas at 2.5 gwei, a funded liquidation uses about 1M
    )
    return s


def totals(s):
    u, w, a = s["usdc"], s["wavax"], s["avax"]
    ledger_usdc = u["market_seed"] + u["team_supply"] + u["flash_vault"] + u["insurance"] + u["vault_team_seed"]
    ledger_wavax = w["market_seed"] + w["vault_team_seed"]
    return dict(
        ledger_usdc=ledger_usdc, ledger_wavax=ledger_wavax, ledger_avax=a["ledger_total"],
        operators_usdc=u["operator_each"] * 2, treasury_usdc=u["treasury"],
        all_usdc=ledger_usdc + u["operator_each"] * 2 + u["treasury"],
        all_avax=a["ledger_total"] + a["deployer"] + a["operator_each"] * 2 + a["keeper"] + a["rebalancer"],
    )


def fmt(x, p=2):
    return f"{q(x, p, ROUND_CEILING):,}"


def budget(s, bal):
    """Balances of the Ledger against what the table sends / wraps / spends. bal = dict(usdc, avax, demo_avax) or None."""
    if not bal:
        return []
    t, a, w = totals(s), s["avax"], s["wavax"]
    L = ["## Budget against the Ledger balance (read from chain)\n"]
    usdc_need = t["all_usdc"]
    L.append("| USDC | |\n|---|---:|")
    L.append(f"| Ledger balance | {fmt(bal['usdc'])} |")
    L.append(f"| Needed (Ledger stages + operators + treasury) | {fmt(usdc_need)} |")
    gap = usdc_need - bal["usdc"]
    L.append(f"| **{'SHORT by' if gap > 0 else 'Spare'}** | **{fmt(abs(gap))}** |\n")
    wrap = t["ledger_wavax"]
    out = a["deployer"] + a["operator_each"] * 2 + a["keeper"] + a["rebalancer"]
    spare = bal["avax"] - bal["demo_avax"] - wrap - out - a["ledger_total"]
    L.append("| AVAX | |\n|---|---:|")
    L.append(f"| Ledger balance | {fmt(bal['avax'], 4)} |")
    L.append(f"| Your own demo collateral (not pilot capital, not allocated) | {fmt(bal['demo_avax'], 4)} |")
    L.append(f"| Pilot AVAX budget | {fmt(bal['avax'] - bal['demo_avax'], 4)} |")
    L.append(f"| Wrapped into WAVAX for the seeds ({fmt(wrap, 4)} WAVAX, 1:1) | {fmt(wrap, 4)} |")
    L.append(f"| Sent to the five wallets (4 hosts at 0.1, deployer {fmt(a['deployer'], 4)}) | {fmt(out, 4)} |")
    L.append(f"| Ledger gas for PW30, vaults, R3, margin stages 2-4 (measured/estimated x 1.5) | {fmt(a['ledger_total'], 4)} |")
    L.append(f"| **{'SHORT by' if spare < 0 else 'Spare inside the pilot budget'}** | **{fmt(abs(spare), 4)}** |")
    if gap > 0 and spare > 0:
        L.append(f"\nThe USDC gap is {fmt(gap)} USDC = about {fmt(gap / s['avax_usd'] * D('1.03'), 3)} AVAX (3% swap slippage and fee margin); the AVAX spare covers it.")
    return L + [""]


def table(s, illustrative=False, bal=None):
    u, w, a, m, t, oc = s["usdc"], s["wavax"], s["avax"], s["margin"], totals(s), s["operator_config"]
    L = []
    L.append(f"# Pilot sizing at CAP = USD {fmt(s['cap_usd'], 0)} (AVAX = USD {fmt(s['avax_usd'], 3)}, gas {a['gas_gwei']} gwei)\n")
    if illustrative:
        L.append("**STATUS: ILLUSTRATIVE (the research size) until the operator confirms the real CAP from the funded balances. Nothing is signed from this table.**\n")
    L.append("Generated by `contracts/tools/pilot-sizing.py`; every number is linear in CAP (the USDC borrow cap). Same contracts and PW30 parameters as the research size (USD 5,000). Caps are raised later by a parameter change.\n")
    L.append("## Funding (what you send)\n")
    L.append("| Wallet | USDC | WAVAX | AVAX | Purpose |\n|---|---:|---:|---:|---|")
    L.append(f"| **Ledger** `0x064e…B2dD` | {fmt(t['ledger_usdc'])} | {fmt(t['ledger_wavax'], 4)} | {fmt(a['ledger_total'], 3)} | PW30 market seeds {fmt(u['market_seed'])} USDC + {fmt(w['market_seed'], 4)} WAVAX; team supply {fmt(u['team_supply'])}; flash vault {fmt(u['flash_vault'])}; insurance {fmt(u['insurance'])}; vault team seeds {fmt(u['vault_team_seed'])} USDC + {fmt(w['vault_team_seed'], 4)} WAVAX. AVAX: PW30 30 txs ({fmt(a['ledger_pw30'], 3)}), vaults, R3, margin stages 2-4 (all signed on the Ledger), measured/estimated gas x 1.5 |")
    L.append(f"| Operator 1 | {fmt(u['operator_each'])} | 0 | {fmt(a['operator_each'], 2)} | liquidation inventory (0.89 x CAP) |")
    L.append(f"| Operator 2 | {fmt(u['operator_each'])} | 0 | {fmt(a['operator_each'], 2)} | liquidation inventory |")
    L.append(f"| Treasury keeper | {fmt(u['treasury'])} | 0 | {fmt(a['keeper'], 2)} | protection capital (0.24 x CAP) |")
    L.append(f"| Rebalancer | 0 | 0 | {fmt(a['rebalancer'], 2)} | vault rebalancing gas only |")
    L.append(f"| Throwaway deployer | 0 | 0 | **{fmt(a['deployer'], 3)}** | margin stage 1: 22 transactions, 31.9M gas measured x 1.5 at {a['gas_gwei']} gwei (unused AVAX is swept back) |")
    L.append(f"| **Total** | **{fmt(t['all_usdc'])}** | **{fmt(t['ledger_wavax'], 4)}** | **{fmt(t['all_avax'], 3)}** | |\n")
    L += budget(s, bal)
    L.append("## Parameters\n")
    L.append("| Item | Value |\n|---|---:|")
    L.append(f"| USDC borrow cap (PW30) / margin position cap / margin debt cap | {fmt(u['borrow_cap'], 0)} / {fmt(m['position_cap'], 0)} / {fmt(m['debt_cap'], 0)} USD |")
    L.append(f"| USDC borrow cash floor (20% of supply) | {fmt(u['cash_floor'])} USDC |")
    L.append(f"| WAVAX borrow cap (borrowing stays paused) | {fmt(w['wavax_borrow_cap'], 4)} WAVAX |")
    L.append(f"| Vault deposit caps | {fmt(u['borrow_cap'], 0)} USDC; {fmt(w['vault_cap'], 4)} WAVAX (about USD {fmt(s['cap_usd'], 0)}) |")
    L.append(f"| Team lending-borrow rule during the pilot (margin needs room) | at most {fmt(u['team_borrow_rule'], 0)} USDC |")
    L.append(f"| Operator caps: per liquidation call / per rolling 24 h each | {oc['marginMaxRepayPerCallUsdc']} / {oc['marginDailyRepayCapUsdc']} USDC |")
    L.append(f"| Operator inventory alert floor / target | {oc['operatorInventoryMinUsd']} / {oc['operatorInventoryTargetUsd']} USD |")
    L.append(f"| Keeper protection capital / daily spend cap | {oc['protectionCapitalUsd']} / {oc['keeperDailySpendCapUsdc']} USD |")
    L.append(f"| Process AVAX alert floor (operators, keeper, rebalancer) | {fmt(a['process_floor'], 2)} AVAX |\n")
    L.append("Seeds: lending market seed 2% of CAP per asset (at least USD 10); vault team seed 5% of CAP per vault (at least USD 10). They are the 'minimal' values of this table; the research size used 2% and 10%.\n")
    return "\n".join(L) + "\n"


def check(cap):
    if cap < CAP_MIN or cap > CAP_MAX:
        sys.exit(f"CAP {cap} is outside [{CAP_MIN}, {CAP_MAX}] USD: below it the seeds and floors stop making sense, above it the pilot cap decision (USD 5,000) is exceeded")


def write_all(s, illustrative=False, bal=None):
    u, w, m = s["usdc"], s["wavax"], s["margin"]
    cap = s["cap_usd"]
    pw = f"""# Cash-only lending PW30: the 20 deployment inputs (PUBLIC values only; no key, no endpoint). GENERATED by tools/pilot-sizing.py at CAP = USD {cap} and AVAX = USD {s['avax_usd']}.
# Everything that scales is linear in CAP; rates, factors, close factor and incentive are the PW30 parameters, unchanged. Used by tools/avalanche-ceremony.sh.
export DEPLOYER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
export PERIDOT_TOKEN=0x0000000000000000000000000000000000000000
export LENDING_ALLOW_NO_REWARD_TOKEN=true
export PAUSE_GUARDIAN=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
# seeds (held by the market forever, see the bootstrapper): 2% of CAP per asset, at least USD {SEED_FLOOR_USD}
export LENDING_WAVAX_SEED_AMOUNT={units(w['market_seed'], 18)}
export LENDING_USDC_SEED_AMOUNT={units(u['market_seed'], 6)}
# borrow caps: USDC = CAP; WAVAX borrowing stays PAUSED (the cap only bounds a mistake: 0.2 x CAP in WAVAX)
export LENDING_WAVAX_BORROW_CAP={units(w['wavax_borrow_cap'], 18)}
export LENDING_USDC_BORROW_CAP={units(u['borrow_cap'], 6)}
export LENDING_RESERVE_FACTOR=100000000000000000
export LENDING_CLOSE_FACTOR=500000000000000000
export LENDING_LIQUIDATION_INCENTIVE=1080000000000000000
# Avalanche C-Chain mines a block about every 0.94 s (14-day measurement: 0.936 s): 33.5 million blocks a year
export LENDING_BLOCKS_PER_YEAR=33500000
export LENDING_BASE_RATE_PER_YEAR=20000000000000000
export LENDING_MULTIPLIER_PER_YEAR=100000000000000000
export LENDING_JUMP_MULTIPLIER_PER_YEAR=1000000000000000000
export LENDING_KINK=800000000000000000
export AVAX_FEED_MAX_AGE=1200
export USDC_FEED_MAX_AGE=90000
export LENDING_WAVAX_BORROW_CASH_FLOOR=0
# 20% of the intended supply (1.25 x CAP)
export LENDING_USDC_BORROW_CASH_FLOOR={units(u['cash_floor'], 6)}
"""
    open(os.path.join(ROOT, "ceremony", "pilot-pw30.env"), "w").write(pw)
    mg = f"""# Margin 2x sizing inputs (PUBLIC). GENERATED by tools/pilot-sizing.py at CAP = USD {cap}. The script derives the pair's position cap (= CAP) and debt cap (= CAP/2) from MARGIN_CAP_USD.
export MARGIN_CAP_USD={int(cap)}
export MARGIN_FLASH_SEED_USDC={units(u['flash_vault'], 6)}
export MARGIN_INSURANCE_SEED_USDC={units(u['insurance'], 6)}
export MARGIN_ACTION_DELAY=86400
"""
    open(os.path.join(ROOT, "ceremony", "margin-sizing.env"), "w").write(mg)
    js = dict(
        cap_usd=int(cap), avax_usd=str(s["avax_usd"]), operator_config=s["operator_config"],
        vaults=dict(usdc_deposit_cap_units=units(u["borrow_cap"], 6), wavax_deposit_cap_units=str(units(w["vault_cap"], 18)), usdc_team_seed_units=units(u["vault_team_seed"], 6), wavax_team_seed_units=str(units(w["vault_team_seed"], 18))),
        process_gas_floor_wei=str(units(s["avax"]["process_floor"], 18)),
    )
    open(os.path.join(ROOT, "ceremony", "pilot-sizing.json"), "w").write(json.dumps(js, indent=2) + "\n")
    open(os.path.join(REPO, "docs", "deployment-handoffs", "avalanche-pilot-sizing-table.md"), "w").write(table(s, illustrative, bal))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap-usd", required=True, type=D)
    ap.add_argument("--avax-usd", required=True, type=D)
    ap.add_argument("--gas-gwei", default=D("2.5"), type=D)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--illustrative", action="store_true", help="mark the generated table as not yet confirmed by the operator")
    ap.add_argument("--ledger-usdc", type=D, help="Ledger USDC balance read from chain (adds the budget section)")
    ap.add_argument("--ledger-avax", type=D, help="Ledger AVAX balance read from chain")
    ap.add_argument("--demo-avax", type=D, default=D("0"), help="AVAX that is the operator's own demo collateral and is not allocated")
    a = ap.parse_args()
    bal = dict(usdc=a.ledger_usdc, avax=a.ledger_avax, demo_avax=a.demo_avax) if a.ledger_usdc is not None and a.ledger_avax is not None else None
    check(a.cap_usd)
    s = sizing(a.cap_usd, a.avax_usd, a.gas_gwei)
    print(table(s, a.illustrative, bal))
    if a.write:
        write_all(s, a.illustrative, bal)
        print("written: contracts/ceremony/pilot-pw30.env, margin-sizing.env, pilot-sizing.json, docs/deployment-handoffs/avalanche-pilot-sizing-table.md")


if __name__ == "__main__":
    main()
