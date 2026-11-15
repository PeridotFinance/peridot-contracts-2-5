#!/usr/bin/env python3
"""Generate the "Avalanche margin 2x" subsection of contracts/addresses.MD from the machine-readable file
docs/deployment-handoffs/avalanche-pilot-addresses.json (key `margin`).

* The JSON is only READ. Nothing is typed by hand: every address printed comes from the JSON and is checked to be
  EIP-55 checksummed (pure-Python Keccak-256, no dependency) before anything is written; an invalid one aborts.
* Only the text between the two marker lines is written. If the markers are not in the file yet, the block is appended
  at the end of the file (the PW30 section is the last section). Nothing else in addresses.MD is changed.
* Idempotent: running it twice gives the same file. `--check` writes nothing and exits 1 if the file is out of date.

Usage: python3 contracts/tools/gen-margin-addresses-md.py [--json PATH] [--md PATH] [--check]
"""
import argparse
import json
import os
import re
import sys

BEGIN = "<!-- BEGIN GENERATED: avalanche-margin-2x (contracts/tools/gen-margin-addresses-md.py from docs/deployment-handoffs/avalanche-pilot-addresses.json; do not edit between the markers) -->"
END = "<!-- END GENERATED: avalanche-margin-2x -->"

# ---------------------------------------------------------------- Keccak-256 (for EIP-55 only)
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
       0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
       0x000000000000800A, 0x800000008000000A, 0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(x, n):
    n %= 64
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * ((-len(msg)) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i: off + 8 * i + 8], "little")
        for rnd in range(24):
            c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
            a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            b = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
            a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            a[0][0] ^= _RC[rnd]
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(rate // 8))
    return out[:32]


def checksum(addr: str) -> str:
    h = addr[2:].lower()
    dig = keccak256(h.encode()).hex()
    return "0x" + "".join(c.upper() if int(dig[i], 16) >= 8 else c for i, c in enumerate(h))


def eip55(addr: str) -> str:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", addr or ""):
        sys.exit(f"not an address: {addr!r}")
    if addr != checksum(addr):
        sys.exit(f"address is not EIP-55 checksummed: {addr}")
    return addr


# self-test against two published EIP-55 vectors
assert checksum("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") == "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
assert checksum("0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359") == "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"

# ---------------------------------------------------------------- content
# Display order and short titles (hard-coded here; every ADDRESS comes from the JSON, and a margin address key missing from this list aborts the run).
ORDER = [
    ("executor", "IsolatedMarginExecutorUpgradeable (Proxy USE THIS: open, add margin, repay, close)"),
    ("vault", "IsolatedMarginVaultUpgradeable (Proxy: margin deposits, pUSDC)"),
    ("quoter", "IsolatedMarginQuoter (opening quote)"),
    ("riskEngine", "IsolatedMarginRiskEngineUpgradeable (Proxy: metrics, health factor; the controller's isolated-margin risk hook)"),
    ("config", "IsolatedMarginConfigUpgradeable (Proxy: pair risk, fees, opensPaused)"),
    ("orderRegistry", "MarginOrderRegistry (Proxy: take-profit / stop-loss orders)"),
    ("closeAdapter", "AvalancheMarginCloseAdapter (order close path)"),
    ("liquidator", "IsolatedMarginLiquidatorUpgradeable (Proxy)"),
    ("flashLoanVault", "SimpleFlashLoanVault (USDC flash lender, fee 0)"),
    ("swapModule", "IsolatedMarginSwapModule"),
    ("routerAdapter", "PharaohCLRouterAdapter (the one WAVAX/USDC pool route)"),
    ("accountFactory", "IsolatedMarginAccountFactory"),
    ("accountImplementation", "IsolatedMarginAccount (Implementation cloned once per position)"),
    ("feeDistributor", "MarginFeeDistributorUpgradeable (Proxy)"),
    ("insuranceFund", "MarginInsuranceFundUpgradeable (Proxy)"),
    ("oracle", "GuardedAvalanchePriceOracle (the PW30 oracle, reused)"),
    ("executorImplementation", "IsolatedMarginExecutorUpgradeable (Implementation)"),
    ("orderRegistryImplementation", "MarginOrderRegistry (Implementation)"),
]


def render(d):
    m = d["margin"]
    for k, _ in ORDER:
        if k not in m:
            sys.exit(f"margin.{k} missing in the JSON")
    listed = {k for k, _ in ORDER}
    extra = [k for k in m if isinstance(m[k], str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", m[k]) and k not in listed]
    if extra:
        sys.exit(f"margin address keys not in the display order: {extra}")
    ledger = eip55(m["owner"]["address"])
    pr = m["pairRisk"]
    en = m["enable"]
    lines = [BEGIN, ""]
    lines.append(
        f"Avalanche C-Chain mainnet (chain {d['chainId']}), MARGIN 2x on top of PW30 (long WAVAX against USDC, up to {pr['maxLeverageX100'] / 100:g}x, one isolated account per position), "
        f"enabled {en['timestampUtc'][:10]} (block {en['block']}, tx {en['tx']}). Owner of every contract and proxy admin: the Ledger {ledger} (an EOA, not the Safe). "
        f"Pilot caps: position USD {pr['maxPositionValueUsd']}, debt USD {pr['maxDebtValueUsd']}. "
        "Machine-readable copy with ABIs: docs/deployment-handoffs/avalanche-pilot-addresses.json (key margin). "
        f"Frontend notes: {m['frontendHandoff']}."
    )
    lines.append("")
    for k, title in ORDER:
        lines.append(f"{title}: {eip55(m[k])}")
    lines.append("")
    p = m["pair"]
    lines.append(f"Pair (the only one enabled): margin and debt pUSDC {eip55(p['marginPToken'])}, position pWAVAX {eip55(p['positionPToken'])}; "
                 f"USDC {eip55(p['marginUnderlying'])}, WAVAX {eip55(p['positionUnderlying'])}; controller (Unitroller) {eip55(d['lending']['controller'])}")
    lines.append(f"Pair risk (read from chain): max leverage {pr['maxLeverageX100']}/100, initial margin {pr['initialMarginBps']} bp, maintenance {pr['maintenanceMarginBps']} bp, "
                 f"liquidation target {pr['liquidationTargetBps']} bp, full liquidation at health <= {pr['fullLiquidationHealthBps']} bp, max partial liquidation {pr['maxLiquidationBps']} bp of the debt, "
                 f"bonus {pr['liquidationBonusBps']} bp, max slippage {pr['maxSlippageBps']} bp, oracle deviation {pr['oracleDeviationBps']} bp")
    fl = m["fundedLiquidators"]["liquidateFunded"]
    lines.append("Funded liquidators (liquidateFunded): " + ", ".join(eip55(a) for a in fl))
    fv = m["flashVault"]
    lines.append(f"Flash vault: USDC only, fee {fv['feeBps']} bp, balance {int(fv['usdcBalanceRaw']) / 1e6:g} USDC. Insurance fund seed: {m['insuranceFundState']['seedUsdc']} USDC (as pUSDC).")
    lines.append(f"Swap venue: Pharaoh CL pool {eip55(m['swapVenue']['pool'])} (tick spacing {m['swapVenue']['tickSpacing']}), router {eip55(m['swapVenue']['router'])}")
    lines.append("")
    lines.append(END)
    return "\n".join(lines) + "\n"


def splice(text, block):
    if BEGIN in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1 or text.index(BEGIN) > text.index(END):
            sys.exit("addresses.MD has broken markers; fix by hand")
        head = text[: text.index(BEGIN)]
        tail = text[text.index(END) + len(END):]
        if tail.startswith("\n"):
            tail = tail[1:]
        return head + block.rstrip("\n") + "\n" + tail
    sep = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    return text + sep + block


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default=os.path.join(repo, "docs/deployment-handoffs/avalanche-pilot-addresses.json"))
    ap.add_argument("--md", default=os.path.join(repo, "contracts/addresses.MD"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    with open(a.json) as f:
        d = json.load(f)
    block = render(d)
    with open(a.md) as f:
        old = f.read()
    new = splice(old, block)
    if a.check:
        sys.exit(0 if new == old else 1)
    if new != old:
        with open(a.md, "w") as f:
            f.write(new)
        print(f"updated {a.md}")
    else:
        print("already up to date")


if __name__ == "__main__":
    main()
