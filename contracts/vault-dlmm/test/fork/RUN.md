# DLMM vault mainnet-fork tests (W6)

Real pool `0x16888EE58E706C253b821EAA637ae9b2cFeA255C`, real Pharaoh DLMM router/rewarder/voter, real Chainlink USDC/USD and USDT/USD, Avalanche C-chain (43114).
Nothing is signed or sent: the fork is local, funding is `deal()`, roles are `vm.prank`, feed depegs are `vm.mockCall` on `latestRoundData`.

## Command (environment variable only)

The endpoint is read from the environment variable that `contracts/vault-dlmm/foundry.toml` already references: **`AVALANCHE_MAINNET_RPC_URL`**
(the task brief said `AVALANCHE_RPC`; the existing foundry.toml alias `avalanche = "${AVALANCHE_MAINNET_RPC_URL}"` is used unchanged, so export that one).
Never put the URL in a file or a command-line argument.

```
cd contracts/vault-dlmm
export AVALANCHE_MAINNET_RPC_URL=...            # your shell, not a file
./test/fork/run-locked.sh --match-path test/fork/DlmmVaultFork.t.sol          # all groups
./test/fork/run-locked.sh --match-contract DlmmForkDepeg -vv                   # one group
```

`run-locked.sh` compiles first (no lock held), then takes the shared fork lock `/tmp/pilot-fork.lock` (`mkdir`, retry every 30 s, `rmdir` on every exit path via trap),
runs `forge test` with `DLMM_FORK_BLOCK` pinned (default `100420249`, override by exporting it), writes the log to `$TMPDIR/dlmm-fork-run.log` and prints it with every
`http(s)://...` redacted. Lock timestamps go to `$TMPDIR/dlmm-fork-lock-minutes.log`. A plain `forge test` in this folder SKIPS the fork tests (they are gated on `DLMM_FORK_BLOCK`).
Runs are fast (a cached fork block: the whole file takes about 2 s of lock time after the first fetch).

## Expected result at block 100420249 (15 Nov 2026)

| Contract | What | Tests |
| --- | --- | --- |
| DlmmForkInit | (1) initialize: 14 checks, one negative each, cap ceiling, double init | 20 |
| DlmmForkHappy | (2) ceremony path, composition cost, round trip; (8) cap, mint path, donation, drift | 8 |
| DlmmForkHarvest | (3) PHAR claim, 111 s window (5 delays), old-band rewards, no band, access, feeds-independent | 10 |
| DlmmForkRebalance | (4) up/down, ActiveIdMoved, cooldown, daily cap, SwapTooLarge, loss bound, one-sided adds | 13 |
| DlmmForkDepeg | (5) per leg x both directions lifecycle, gradual path, bit 16, feed failures, latch | 10 |
| DlmmForkExit | (6) in-kind/redeem under latch, pause, bad feeds, 100 % one asset, deep pool depeg, dust | 18 |
| DlmmForkHook | (7) failing hook on the real pair, bit 32 cases | 11 |
| **Total** | | **90 passed, 0 failed** (7 suites) |

Plain `forge test` (no `DLMM_FORK_BLOCK`): each fork suite skips in `setUp` (reported as 7 skipped); `W2Smoke.t.sol` runs as before (15 passed).

## Notes for the reader

- Numbers pinned by asserts (dust thresholds 3 and 6 shares, feed-failure bit patterns, loss-bound cut-off at 4 bins) are MEASURED at the pin block; at another block
  the pool depth, feed ages or reward accrual differ and a few asserts may need new values. The structural asserts (error selectors, guard bits, latch, ordering) do not depend on the block.
- Feed ages: the real feeds are 4 to 6 h old at the pin (limit 26 h). Tests that warp use the explicit clock (`_warpBy` / `_ts()`): via-IR may reuse a `block.timestamp` read across `vm.warp`.
- `vm.mockCall` is used for the Chainlink answers (the feeds' storage is never written), for the rewarder/voter/beacon/pair reads in the init checks and for the failing hook.
  `vm.clearMockedCalls()` is the un-mock.
- Hook selectors (MEASURED from a -vvvv trace of a real burn): `beforeBurn(address,address,address,uint256[],uint256[])` = `0xea9db9d3`, `beforeSwap(address,address,bool,bytes32)` = `0xfeee3735`,
  `beforeMint(address,address,bytes32[],bytes32)`.
