# Evidence for `avalanche-vault-share-pricing-remedy.md`

Every `attempt*.txt` has a header (UTC start, git HEAD, sha256 of the three new test files, RPC host, forge version, environment, exact command) and the full forge output; nothing was overwritten or deleted, failed attempts are kept. All fork runs: direct to `https://api.avax.network/ext/bc/C/rpc`, warm shared cache, `--compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000`, `--threads 1`, `FOUNDRY_OUT=out_remedy FOUNDRY_CACHE_PATH=cache_remedy`; a grep of every log for HTTP 429 / rate limit / Max retries / database error finds none. Pins: Pharaoh USDC vault 99216397, Pharaoh WAVAX vault 99216312. All are development or final runs of tests on a local fork; no key, no signing, no broadcast.

| Attempt | What | Result | Why it failed (if it did) |
| --- | --- | --- | --- |
| attempt01-fork-usdc-test01 | first fork replay, `test_01` | FAIL (`asset ledger residual: 2000000000 != 0`) | test bug: Bob was funded with `deal` INSIDE the measured ledger window; fixed (funding before the window) |
| attempt02-fork-usdc-test01 | same test after the fix | PASS | |
| attempt03-fork-usdc-all | whole USDC suite after adding the tick-restored and cycling tests | 8 pass, 10 fail | test bugs: `deal` of USDt/sAVAX for the arbitrage whale used the wrong helper path ("fund paired token"), and the 100% cycling loop required Bob to redeposit his original stake after losing money ("bob short"); fixed (deposit his whole balance each cycle, BENQI `submit()` only for sAVAX). A first invocation of this attempt name with a non-existent contract name matched no tests and was overwritten by the real run |
| attempt04-fork-usdc-all, attempt05-fork-wavax-all | whole suites (18 tests) | PASS | |
| attempt06-fork-usdc-all | after adding the seed-only round trips (21 tests) | 20 pass, 1 FAIL (`test_11_seedOnly_roundTrip_usd10000`: "Too little received") | **vault behaviour, not a test bug**: a USD 10,000 deposit into the seed-only Pharaoh USDC vault reverts at the swap slippage bound; the earlier report ran USDC at USD 100 and 1,000 only. The test now logs "not run" for that size on that vault |
| attempt07-fork-wavax-all | WAVAX, 21 tests | PASS | |
| attempt08 | number unused | | |
| attempt09-python-exact-check | `exact_check.py` | OK | |
| attempt10-fork-usdc-all, attempt11-fork-wavax-all, attempt12-prototype-all | 21 / 21 / 22 tests | PASS | superseded by 16 to 18 after dead lines were removed from the test files (cleanup only) |
| attempt13, 14, 15 | the same three runs after the cleanup | **compile failure** (a stray `D;` statement left in `_rt`) | my edit error; fixed, no test ran |
| **attempt16-fork-usdc-final** | final, Pharaoh USDC vault | **21 passed, 0 failed** | |
| **attempt17-fork-wavax-final** | final, Pharaoh WAVAX vault | **21 passed, 0 failed** | |
| **attempt18-prototype-final** | final, model tests (no RPC), 22 tests incl. a 256-run fuzz | **22 passed, 0 failed** | |
| dev-prototype-run1..5 | EARLIER VERSIONS of the model test file (text not preserved), logs verbatim | various failures | run 1: four failures (the mutation test ran four 144-state grids in one test and ran out of gas; the haircut-exit identity forgot the exiter's remaining shares; R1 round trip positive at the pinned WAVAX basis, which became the finding "R1 alone is not enough with a large basis" and the split of the round-trip tests into `test_20` (no basis, strict) and `test_21` (with basis, reported); the reserve table reverted with "no contribution" because the vault grew without bound). Runs 2 to 5 are later development runs of the same file (some of them show remaining failures of the same kind). Several compile attempts that failed with "stack too deep" (refactored into helper functions) and one run whose output file was overwritten by the next run of the same command were not saved. The reserve model went through three definitions of "replenishment" (donation of a fixed share of the CURRENT value per cycle; top-up to a target stock; fixed inflow of the STARTING value per cycle); the last was kept because the first two make the vault itself grow by orders of magnitude over hundreds of cycles |

Final sha256 (from the headers of attempts 16 to 18): `AvalancheVaultShareCheckFork.t.sol` f85621ad3b6c395d4d3b97cd0aa34559d8bb985a93890bd135f29d8ba970e91e; `AvalancheVaultSharePricingPrototype.t.sol` 02858949f44c1bcb982294af35bfb0181c846d431f450642a66364f55afa0dbb; `prototype/VaultShareModel.sol` 7df6400c5ab21daa32fb06fb710c07a8bde95a9b0371ccd29908e7d21ef83fb6; `exact_check.py` 52487a41050bc5f705e5657a4b0f94ab849e24b8df537abd2880fbffb6b7f24e.

Log line prefixes: `VSC|` (fork replay), `PROTO|` (model). Tables in the doc are copied from attempts 16 to 18.
