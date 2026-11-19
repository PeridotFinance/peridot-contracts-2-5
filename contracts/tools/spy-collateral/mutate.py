"""Hand-written mutants for the pSPY collateral delegate and the flash liquidator: each must make the unit suite fail.
Run from contracts/:  python3 tools/spy-collateral/mutate.py   (restores every file; prints KILLED/SURVIVED per mutant)."""
import os, subprocess, sys, pathlib
S = 'contracts/margin/spy/'
D = S + 'RobinhoodSpyCollateralDelegate.sol'
L = S + 'SpyCollateralLiquidator.sol'
MUTANTS = [
    (D, 'if (tokens != 0 && !_isMarginAccount(account)) {', 'if (tokens != 0) {'),
    (D, 'if (tokens != 0 && !_isMarginAccount(account)) {', 'if (!_isMarginAccount(account)) {'),
    (D, 'if (reason != 0) return (reason, 0, 0, 0);', ''),
    (D, 'if (reason != 0) return (reason, 0, 0, 0);', 'if (reason > 1) return (reason, 0, 0, 0);'),
    (D, '            return SOURCE_UNREADABLE;', '            return 0;'),
    (D, 'if (!_isMarginAccount(msg.sender)) {\n            uint256 total', 'if (true) {\n            uint256 total'),
    (D, 'if (!_isMarginAccount(msg.sender)) {\n            uint256 total', 'if (false) {\n            uint256 total'),
    (D, 'if (total > lendingSupplyCap)', 'if (total > lendingSupplyCap + 1e12)'),
    (D, 'if (total > lendingSupplyCap)', 'if (total >= lendingSupplyCap)'),
    (D, 'if (accountTokens[msg.sender] == sharesBefore) revert ZeroSharesMinted();', ''),
    (D, '(redeemAmount * expScale + rate - 1) / rate', '(redeemAmount * expScale) / rate'),
    (D, 'if (data.length != 32) revert InvalidConfiguration();', ''),
    (D, '    function _setLendingSupplyCap(uint256 newCap) external {\n        if (msg.sender != admin) revert OnlyAdmin();', '    function _setLendingSupplyCap(uint256 newCap) external {'),
    (D, 'lendingSupplyCap = newCap;', ''),
    (D, 'return totalSupply * exchangeRateStoredInternal() / expScale;', 'return totalSupply;'),
    (D, 'if (reason != 0) revert SpySessionClosed(reason);', ''),
    (L, 'if (reason != 0) revert SpyPriceUnavailable(reason);\n        _borrower', '_borrower'),
    (L, 'msg.sender != address(flashLender) || initiator != address(this)', 'initiator != address(this)'),
    (L, '|| borrower == address(0)', ''),
    (L, '* (BPS - maxSlippageBps) / BPS', '* (BPS - 10 * maxSlippageBps) / BPS'),
    (L, 'if (profit != 0) usdg.safeTransfer(beneficiary, profit);', ''),
    (L, '|| beneficiary_ == address(0)', ''),
    (L, '|| maxSlippageBps_ > 500', ''),
    (L, '|| debtMarket_ == collateralMarket_', ''),
    (L, 'if (repayAmount == 0) revert ZeroRepay();', ''),
]
def run():
    r = subprocess.run(['forge', 'test', '--match-path', 'test/spy/SpyCollateralDelegate.t.sol'],
                       env={**os.environ, 'FOUNDRY_PROFILE': 'robinhood_spy'}, capture_output=True, text=True)
    if 'Compiler run failed' in r.stdout + r.stderr or 'Error (' in r.stderr:
        return None
    return r.returncode == 0
assert run() is True, 'baseline suite must compile and pass'
killed = 0
for i, (f, a, b) in enumerate(MUTANTS):
    p = pathlib.Path(f); orig = p.read_text()
    if orig.count(a) != 1: print(f'{i} BADPATTERN {a!r}'); continue
    p.write_text(orig.replace(a, b))
    try: ok = run()
    finally: p.write_text(orig)
    if ok is None: print(f'{i:2d} NOCOMPILE {a[:60]!r}'); continue
    killed += not ok
    print(f'{i:2d} {"SURVIVED" if ok else "KILLED  "} {pathlib.Path(f).name}: {a[:60]!r}', flush=True)
print(f'{killed}/{len(MUTANTS)} killed')
sys.exit(0 if killed == len(MUTANTS) else 1)
