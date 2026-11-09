#!/usr/bin/env python3
"""R-C mutation check of the margin 2x contracts and ceremony script (fork suite AvalancheMarginMainnetRehearsalForkTest).

Each mutant is one exact, single-occurrence text replacement in a source file. The harness applies it, runs ONLY the tests that own that rule
(`forge test --match-test`), records whether the suite FAILED (= the mutant is KILLED, which is what we want), and restores the file from a
byte-exact backup in a `finally` block (and verifies the restore by hash). A mutant that survives means a rule no test protects.

A mutant that fails to COMPILE is reported as INVALID (not killed): a compile error proves nothing about the tests.

Usage (one fork job at a time; the endpoint comes from the environment, never from an argument):
    AVALANCHE_MAINNET_RPC_URL=... python3 tools/margin-mutation-check.py [--only A1,W2] [--out evidence.txt]
"""
import hashlib
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # contracts/
ADAPTER = "contracts/margin/orders/AvalancheMarginCloseAdapter.sol"
SCRIPT = "script/DeployAvalancheMarginMainnet.s.sol"
OUT, CACHE = "out_margin", "cache_margin"
PIN = ""
CONTRACT = "AvalancheMarginMainnetRehearsalForkTest"

# id, file, old text (must occur exactly once), new text, tests that must fail (regex for --match-test), what the rule is
MUTANTS = [
    ("A1", ADAPTER, "        if (p.owner != owner) revert InvalidClose(3);\n", "", "test_06e", "adapter: owner must be the position's owner"),
    ("A2", ADAPTER, "if (!ok || price != oraclePriceE18_) revert InvalidClose(6);", "if (!ok) revert InvalidClose(6);", "test_06e", "adapter: the price must equal the registry's trigger price"),
    ("A3", ADAPTER, "uint16 effective = maxSlippageBps < pairMax ? maxSlippageBps : pairMax;", "uint16 effective = maxSlippageBps;", "test_06f|test_06b", "adapter: order slippage is clamped to the pair's 100 bp"),
    ("A4", ADAPTER, "        if (p.side != IsolatedMarginTypes.Side.LONG) revert InvalidClose(7);\n", "", "test_06e", "adapter: closeFor refuses a short"),
    ("A4b", ADAPTER, "return p.status == IsolatedMarginTypes.Status.ACTIVE && p.side == IsolatedMarginTypes.Side.LONG;", "return p.status == IsolatedMarginTypes.Status.ACTIVE;", "test_06e", "adapter: a short is reported inactive"),
    ("A5", ADAPTER, "return Math.max(floorBySlippage, debt + flashFee);", "return floorBySlippage;", "test_06g", "adapter: the minimum is never below debt plus flash fee"),
    ("A6", ADAPTER, "        if (msg.sender != registry) revert NotRegistry();\n", "", "test_06e", "adapter: only the registry may call closeFor"),
    ("A7", ADAPTER, "        if (adapterData.length != 0) revert AdapterDataNotSupported();\n", "", "test_06e", "adapter: adapterData must be empty"),
    ("A8", ADAPTER, "if (maxSlippageBps == 0 || maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidClose(2);", "if (maxSlippageBps == 0) revert InvalidClose(2);", "test_06e", "adapter: order slippage at most 300 bp"),
    ("W1", SCRIPT, "        fv.setFeeBps(0);\n", "", "test_02_wire|test_03_lifecycle", "script: the flash vault fee is set to 0 (default is 5 bp)"),
    ("W2", SCRIPT, "_setIsolatedMarginRiskHook(d.riskEngine) == 0", "_setIsolatedMarginRiskHook(address(0)) == 0", "test_02_wire|test_03_lifecycle", "script: the controller's risk hook is the risk engine"),
    ("W3", SCRIPT, "            cfg.addFundedLiquidator(p.funders[i]);\n", "            if (i == 0) cfg.addFundedLiquidator(p.funders[i]);\n", "test_02_wire|test_05_funded", "script: every operator becomes a funded liquidator"),
    ("W4", SCRIPT, "            maintenanceMarginBps: 2_500,", "            maintenanceMarginBps: 3_500,", "test_02c", "script: maintenance margin is 25% (pinned literal)"),
    ("W5", SCRIPT, "            maxPositionValueUsd: uint128(capUsd * 1e18),", "            maxPositionValueUsd: uint128(capUsd * 1e19),", "test_02c|test_02d", "script: position cap = the cap (pinned literal and derivation)"),
    ("W9", SCRIPT, "            maxDebtValueUsd: uint128(capUsd * 1e18 / 2)", "            maxDebtValueUsd: uint128(capUsd * 1e18)", "test_02c|test_02d", "script: debt cap = cap / 2"),
    ("W10", SCRIPT, "capUsd <= 5_000", "capUsd <= 50_000", "test_02d", "script: the cap is bounded by the pilot decision (USD 5,000)"),
    ("W11", SCRIPT, '        require(p.flashSeedUsdc >= p.capUsd * 1e6 / 2, "Margin: the flash vault must cover the debt cap (cap / 2)");\n', "", "test_02d", "script: the flash vault must cover the debt cap"),
    ("W6", SCRIPT, "            maxSlippageBps: 100,", "            maxSlippageBps: 300,", "test_02c", "script: slippage floor 100 bp (pinned literal)"),
    ("W7", SCRIPT, 'require(c.borrowGuardianPaused(p.pWavax), "Margin: WAVAX borrowing is not paused");', "", "test_01b", "script: refuses when WAVAX borrowing is not paused (long only)"),
    ("W8", SCRIPT, 'require(p.deployer != p.ledger, "Margin: the deployer must not be the Ledger");', "", "test_01b", "script: the deployer must not be the Ledger"),
]


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def pin_block():
    """The suite follows the live head unless MARGIN_FORK_BLOCK is set; pool depth moves a lot between heads, so a mutation run must see ONE state.
    The endpoint is passed through the environment (ETH_RPC_URL for cast), never as an argument."""
    if os.environ.get("MARGIN_FORK_BLOCK"):
        return os.environ["MARGIN_FORK_BLOCK"]
    env = dict(os.environ, ETH_RPC_URL=os.environ.get("AVALANCHE_MAINNET_RPC_URL", ""))
    r = subprocess.run(["cast", "block-number"], env=env, capture_output=True, text=True)
    return str(int(r.stdout.strip()) - 40)


def run_forge(match):
    cmd = [
        "forge", "test", "--out", OUT, "--cache-path", CACHE, "--match-contract", CONTRACT, "--match-test", match, "--threads", "1", "-vv",
        "--skip", "P_OFTAdapter.sol", "--skip", "P_OFTAdapterUpgradeable.sol", "--skip", "P_OFTAdapterUpgradeable.t.sol",
    ]
    env = dict(os.environ, FOUNDRY_PROFILE="debt_accounting", MARGIN_FORK_BLOCK=PIN)
    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    only = None
    out_path = None
    args = sys.argv[1:]
    if "--only" in args:
        only = set(args[args.index("--only") + 1].split(","))
    if "--out" in args:
        out_path = args[args.index("--out") + 1]
    global PIN
    PIN = pin_block()
    lines = []

    def log(s):
        print(s, flush=True)
        lines.append(s)

    log(f"fork block pinned for every run below: {PIN}")
    # baseline: the owning tests pass on the UNMUTATED sources (otherwise "killed" would mean nothing)
    owners = sorted({m[4] for m in MUTANTS if only is None or m[0] in only})
    log("baseline (unmutated): " + "|".join(owners))
    code, text = run_forge("|".join(owners))
    summary = re.findall(r"Suite result: .*", text)
    log("  " + (summary[-1] if summary else "no suite result") + f"  (exit {code})")
    if code != 0:
        log("BASELINE FAILS: no mutation result below would be meaningful. Stopping.")
        log(text[-3000:])
        finish(lines, out_path)
        sys.exit(2)

    results = []
    for mid, rel, old, new, tests, rule in MUTANTS:
        if only is not None and mid not in only:
            continue
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as f:
            original = f.read()
        before = sha(path)
        text_src = original.decode()
        if text_src.count(old) != 1:
            log(f"{mid}: INVALID (the target text occurs {text_src.count(old)} times, must be exactly 1)")
            results.append((mid, "INVALID"))
            continue
        t0 = time.time()
        try:
            with open(path, "w") as f:
                f.write(text_src.replace(old, new))
            code, text = run_forge(tests)
        finally:
            with open(path, "wb") as f:
                f.write(original)
            if sha(path) != before:
                log(f"{mid}: RESTORE FAILED for {rel}: stop and check git diff")
                sys.exit(3)
        compiled = "Compiler run failed" not in text
        failing = re.findall(r"\[FAIL[^\]]*\]\s+(test_\w+)", text)
        if not compiled:
            verdict = "INVALID (did not compile)"
        elif code != 0 and failing:
            verdict = "KILLED by " + ", ".join(sorted(set(failing)))
        elif code != 0:
            verdict = "KILLED (suite failed)"
        else:
            verdict = "SURVIVED"
        log(f"{mid}: {verdict}   [{rule}]   ({time.time() - t0:.0f} s)")
        results.append((mid, verdict))
    killed = sum(1 for _, v in results if v.startswith("KILLED"))
    survived = [m for m, v in results if v == "SURVIVED"]
    invalid = [m for m, v in results if v.startswith("INVALID")]
    log(f"\nmutants: {len(results)}  killed: {killed}  survived: {survived or 'none'}  invalid: {invalid or 'none'}")
    finish(lines, out_path)
    sys.exit(0 if not survived and not invalid else 1)


def finish(lines, out_path):
    if out_path:
        with open(out_path, "w") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
