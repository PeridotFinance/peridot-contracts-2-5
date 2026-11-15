#!/usr/bin/env python3
"""Render LOSS|ROW / LOSS|EXIT / LOSS|SUM lines of a forge log as markdown tables.
usage: python3 tables.py LOG [group-prefix ...]     (group = the t=... tag, e.g. t=S0_fwd)
USDC amounts are printed in USDC (raw units / 1e6); rate as raw/1e14 (initial rate = 2.0000).
"""
import re
import sys


def parse(path):
    rows, exits, sums = {}, {}, {}
    for line in open(path, errors="replace"):
        line = line.strip()
        if "LOSS|" not in line:
            continue
        line = line[line.index("LOSS|"):]
        parts = line.split("|")
        kind = parts[1]
        kv = {}
        for p in parts[2:]:
            if "=" in p:
                k, v = p.split("=", 1)
                kv[k] = v
        grp = next((p for p in parts[2:] if p.startswith("t=")), None)
        if grp is None:
            continue
        grp = grp[2:]
        if kind == "ROW":
            rows.setdefault(grp, []).append(kv)
        elif kind == "EXIT":
            exits.setdefault(grp, []).append(kv)
        elif kind == "SUM":
            sums[grp] = kv
    return rows, exits, sums


def u(v):
    return f"{int(v) / 1e6:,.2f}"


def main():
    path = sys.argv[1]
    want = sys.argv[2:]
    rows, exits, sums = parse(path)
    for grp in rows:
        if want and not any(grp.startswith(w) for w in want):
            continue
        print(f"\n#### {grp}\n")
        print("| step | cash | recorded borrows | defaulted debt | reserves | rate | claim EARLY | claim LATE | claim BIG | claim SMALL | wd-now EARLY | wd-now LATE | wd-now BIG | wd-now SMALL |")
        print("|" + "---|" * 14)
        for r in rows[grp]:
            print(
                f"| {r['step']} | {u(r['cash'])} | {u(r['borrows'])} | {u(r['defDebt'])} | {u(r['reserves'])} | {int(r['rate']) / 1e14:.6f} | "
                f"{u(r['c_early'])} | {u(r['c_late'])} | {u(r['c_big'])} | {u(r['c_small'])} | "
                f"{u(r['w_early'])} | {u(r['w_late'])} | {u(r['w_big'])} | {u(r['w_small'])} |"
            )
        if grp in exits:
            print("\n| supplier | exit position | claim at exit | received | not received |")
            print("|---|---|---|---|---|")
            for x in exits[grp]:
                print(f"| {x['who']} | {x['pos']} | {u(x['claim'])} | {u(x['got'])} | {u(int(x['claim']) - int(x['got']))} |")
        if grp in sums:
            s = sums[grp]
            print(f"\ntreasury paid in: {u(s['treasuryIn'])}; debt removed: {u(s['removed'])}; absorbed by reserves: {u(s['fromReserves'])}; cash left after all exits: {u(s['cashLeft'])}")


if __name__ == "__main__":
    main()
