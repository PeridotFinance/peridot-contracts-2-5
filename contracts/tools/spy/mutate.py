"""Hand-written mutants for the SPY margin price contracts: each must make the unit suite fail.
Run from contracts/:  python3 tools/spy/mutate.py   (restores every file; prints KILLED/SURVIVED per mutant)."""
import subprocess, sys, pathlib
S = 'contracts/margin/spy/'
MUTANTS = [
    (S+'SpyMarginPriceSource.sol', 'return (timestamp + EPOCH_TO_MONDAY) % WEEK;', 'return timestamp % WEEK;'),
    (S+'SpyMarginPriceSource.sol', 'if (closedFrom == closedUntil) return false;', ''),
    (S+'SpyMarginPriceSource.sol', 'return s >= closedFrom && s < closedUntil;', 'return s > closedFrom && s < closedUntil;'),
    (S+'SpyMarginPriceSource.sol', 'return s >= closedFrom || s < closedUntil;', 'return s > closedFrom || s < closedUntil;'),
    (S+'SpyMarginPriceSource.sol', 'return s >= closedFrom || s < closedUntil;', 'return s >= closedFrom || s <= closedUntil;'),
    (S+'SpyMarginPriceSource.sol', 'return s >= closedFrom || s < closedUntil;', 'return s >= closedFrom && s < closedUntil;'),
    (S+'SpyMarginPriceSource.sol', 'if (p) return (0, STOCK_PAUSED, 0);', ''),
    (S+'SpyMarginPriceSource.sol', 'if (p) return (0, ORACLE_PAUSED, 0);', ''),
    (S+'SpyMarginPriceSource.sol', '            return (0, STOCK_PAUSED, 0);\n        }\n        try', '            return (1, OK, 0);\n        }\n        try'),
    (S+'SpyMarginPriceSource.sol', 'if (answer <= 0 ||', 'if (answer < 0 ||'),
    (S+'SpyMarginPriceSource.sol', '|| updatedAt > block.timestamp)', ')'),
    (S+'SpyMarginPriceSource.sol', 'if (answeredIn < round)', 'if (answeredIn < round - 1)'),
    (S+'SpyMarginPriceSource.sol', 'block.timestamp - updatedAt > maxStaleness', 'block.timestamp - updatedAt >= maxStaleness'),
    (S+'SpyMarginPriceSource.sol', 'if (inClosedWindow(block.timestamp)) return (0, CLOSED_WINDOW, updatedAt);', ''),
    (S+'SpyMarginPriceSource.sol', '10 ** (18 - feedDecimals)', '10 ** (18 - feedDecimals - 1)'),
    (S+'SpyMarginPriceSource.sol', 'if (!_lendingAgrees(stock, priceE18)) return (0, LENDING_MISMATCH, updatedAt);', ''),
    (S+'SpyMarginPriceSource.sol', 'return _lendingAgrees(usd, 1e18) ? 1e18 : 0;', 'return 1e18;'),
    (S+'SpyMarginPriceSource.sol', 'return lendingPrice == priceE18;', 'return lendingPrice >= priceE18;'),
    (S+'SpyMarginPriceSource.sol', '        } catch {\n            return false;', '        } catch {\n            return true;'),
    (S+'SpyMarginPriceSource.sol', 'if (asset != stock) return 0;', ''),
    (S+'SpyMarginPriceSource.sol', 'maxStaleness_ > WEEK', 'maxStaleness_ > WEEK + 1'),
    (S+'SpyMarginPriceSource.sol', 'closedFrom_ >= WEEK ||', 'closedFrom_ > WEEK ||'),
    (S+'SpyMarginPriceSource.sol', 'if (decimals_ > 18)', 'if (decimals_ > 19)'),
    (S+'MarginPriceSourceRouter.sol', 'if (asset == secondaryAsset) return _read(secondary, asset);', ''),
    (S+'MarginPriceSourceRouter.sol', 'if (price != 0 || asset != sharedAsset) return price;', 'if (price != 0) return price;'),
    (S+'MarginPriceSourceRouter.sol', 'if (price != 0 || asset != sharedAsset) return price;', 'if (asset != sharedAsset) return price;'),
    (S+'MarginPriceSourceRouter.sol', '        } catch {\n            return 0;', '        } catch {\n            return 1;'),
    (S+'MarginPriceSourceRouter.sol', '|| primary_ == secondary_)', ')'),
    (S+'MarginPriceSourceRouter.sol', '|| secondaryAsset_ == sharedAsset_)', ')'),
    (S+'RobinhoodLendingPriceAdapter3.sol', 'return source.assetPrices(dollar) * 1e12;', 'return source.assetPrices(dollar) * 1e10;'),
    (S+'RobinhoodLendingPriceAdapter3.sol', 'if (market == secondStockMarket) return source.assetPrices(secondStock);', 'if (market == secondStockMarket) return source.assetPrices(stock);'),
    (S+'RobinhoodLendingPriceAdapter3.sol', 'if (market == secondStockMarket) return source.assetPrices(secondStock);', ''),
    (S+'RobinhoodLendingPriceAdapter3.sol', '&& asset != secondStock) revert', ') revert'),
    (S+'RobinhoodLendingPriceAdapter3.sol', '|| ITokenDecimals3(secondStock_).decimals() != 18', ''),
    (S+'RobinhoodLendingPriceAdapter3.sol', '|| secondStock_ == stock_', ''),
]
def run():
    r = subprocess.run(['forge', 'test', '--no-match-path', 'test/spy/*Fork*'], env={**__import__('os').environ, 'FOUNDRY_PROFILE': 'robinhood_spy'},
                       capture_output=True, text=True)
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
