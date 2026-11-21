"""Hand-written mutants for the pSPY collateral delegate and the flash liquidator: each must make the unit suite fail.
Run from contracts/:  python3 tools/spy-collateral/mutate.py   (restores every file; prints KILLED/SURVIVED per mutant)."""
import os, subprocess, sys, pathlib
S = 'contracts/margin/spy/'
D = S + 'RobinhoodSpyCollateralDelegate.sol'
L = S + 'SpyCollateralLiquidator.sol'
MUTANTS = [
    (D, 'if (tokens != 0 && !_isMarginAccount(account)) {', 'if (tokens != 0) {'),
    (D, 'if (tokens != 0 && !_isMarginAccount(account)) {', 'if (!_isMarginAccount(account)) {'),
    (D, '            if (reason != 0) {\n                if (_hasDebt', '            if (false) {\n                if (_hasDebt'),
    (D, '            if (reason != 0) {\n                if (_hasDebt', '            if (reason > 1) {\n                if (_hasDebt'),
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
    (L, 'uint256 minOut = spyAmount * priceE18 / 1e18 / usdgScale * (BPS - maxSlippageBps) / BPS;', 'uint256 minOut = spyAmount * priceE18 / 1e18 / usdgScale * (BPS - 10 * maxSlippageBps) / BPS;'),
    (L, '        flashLender.flashLoan(this, address(usdg), repayAmount, "");\n        _borrower = address(0);\n        profit = usdg.balanceOf(address(this));\n        if (profit != 0) usdg.safeTransfer(beneficiary, profit);', '        flashLender.flashLoan(this, address(usdg), repayAmount, "");\n        _borrower = address(0);\n        profit = usdg.balanceOf(address(this));'),
    (L, 'if (leftover != 0) nvda.safeTransfer(beneficiary, leftover);\n        profit = usdg.balanceOf(address(this));\n        if (profit != 0) usdg.safeTransfer(beneficiary, profit);', 'if (leftover != 0) nvda.safeTransfer(beneficiary, leftover);\n        profit = usdg.balanceOf(address(this));'),
    (L, '|| beneficiary_ == address(0)', ''),
    (L, '|| maxSlippageBps_ > 500', ''),
    (L, '|| debtMarket_ == collateralMarket_', ''),
    (L, 'if (repayAmount == 0) revert ZeroRepay();', ''),
    (D, 'if (_hasDebt(account)) return (reason, 0, 0, 0);', 'return (reason, 0, 0, 0);'),
    (D, 'if (_hasDebt(account)) return (reason, 0, 0, 0);', ''),
    (D, 'return (NO_ERROR, tokens, 0, 0);', 'return (NO_ERROR, tokens, 0, exchangeRateStoredInternal());'),
    (D, 'if (owed != 0) return true;', ''),
    (L, 'repaid = nvdaOut < maxRepayNvda ? nvdaOut : maxRepayNvda;', 'repaid = nvdaOut;'),
    (L, 'uint256 minNvda = amount * usdgScale * 1e18 / nvdaPrice * (BPS - maxSlippageBps) / BPS;', 'uint256 minNvda = 1;'),
    (L, 'if (leftover != 0) nvda.safeTransfer(beneficiary, leftover);', ''),
    (L, 'if (maxRepayNvda == 0) {', 'if (true) {'),
    (L, 'if (usdgIn == 0 || maxRepay == 0) revert ZeroRepay();', ''),
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
