# W-CAL: depeg-guard calibration, Pharaoh DLMM USDC/USDt vault (read-only, 15 Nov 2026)

Labels: MEASURED (chain or replay data), DERIVED (formula on measured data), ESTIMATED (judgement). Nothing signed or broadcast. The private endpoint was read only through the environment variable (latest-state `eth_call` of `getRoundData`, about 9,600 calls including one aborted run, no 429, no historic-state reads so the fork lock was not needed; the public endpoint was not needed because every feed round is stored on chain and readable by id). Files: `fetch_feeds.py`, `analyze.py`, `depegs.py`, `data/` (all 3,215 USDC and 3,939 USDT rounds since July 2021, `results.json`, `depegs.json`, `band_latch_counts.json`). Window: 30 UTC days 12 Oct 00:00 to 10 Nov 23:59:59 2026; pool series from the evidence folder `data/active_series.json` (read-only).

## 0. Orientation: the spec text, if implemented literally, inverts the bit-16 ratio
MEASURED: pool `getTokenX()` = 0x9702...A8c7 = USDt, `getTokenY()` = 0xB97E...8a6e = USDC. A DLMM price is Y per X, so the oracle price must be USDT/USD over USDC/USD (tokenX feed over tokenY feed). Spec section 4 bit 16 reads "USDC/USD over USDT/USD". I have not seen the contract; if it follows the text, the deviation doubles (26,576 pool events in the window):
| orientation | median | range | max abs |
| --- | --- | --- | --- |
| correct (USDT/USDC) | -0.1 bp | -10.4 to +8.8 bp | 10.4 bp |
| spec literal (USDC/USDT) | -21.0 bp | -49.5 to -14.0 bp | **49.45 bp** |
The "standing pool discount about 11 bp" is mostly the USDT feed (0.9993 to 0.9978), not the pool. The ratio must be built from `pair.getTokenX()/getTokenY()` and a fork test must pin the sign.

## 1. Feeds
Documented (Chainlink reference-data directory for Avalanche mainnet, via WebFetch; the docs page gave 404 and data.chain.link 429, so the primary docs pages were NOT read): heartbeat 86,400 s, deviation 0.1 %, decimals 8, `maxSubmissionValue` 105,000,000. MEASURED on chain: decimals 8; current aggregators (USDC 0xb051...bd3a, USDT 0x05d9...eb25) `minAnswer` 1, `maxAnswer` 105,000,000 (no floor that masks a depeg; cap 1.05). Phase 2 aggregators' first rounds are 28 Aug 2024, phase 3's 3 Aug 2026 (the old aggregators kept updating until 7 Oct 2024 and 6 to 7 Aug 2026). No round has `answeredInRound < roundId` or answer <= 0.

Cadence in the window (MEASURED): USDC updated only on the heartbeat (30 rounds). USDT had 31 rounds, 28 of them at the heartbeat; the 29 Oct 23:43 round came about 9 h after the previous one on a 10 bp move.
| | USDC/USD | USDT/USD |
| --- | --- | --- |
| max age in window | 24.02 h (86,467 s) | 24.01 h (86,429 s) |
| max age ever (5.3 years) | 24.03 h (86,495 s) | 24.03 h (86,495 s) |
| gaps over 26 h, ever | 0 | 0 |
| min / max answer in window | 0.9995753 / 0.9998916 | **0.9977911 (-22.1 bp, 29 Oct)** / 0.9990328 |
Unfavourable: the spec assumed feed noise of 10 bp per leg; USDT reached 22.1 bp off 1.0 in the window and 37 bp in June 2023. Because feeds sit unchanged almost the full 24 h, any `maxFeedAge` below about 86,600 s would trip daily.

## 2. 30-day replay (MEASURED/DERIVED)
Deviation per pool bin-event against the feed round in force. Re-centres tested = the 141 P1 exit-triggered re-centres of the 3-bin geometry (exit + 60 s), reproducing the earlier recount (141).
Correct orientation: 0 events over 20 bp, so for thresholds 40, 50, 60, 80, 100 (and 20, 30): 0 events, 0 minutes, 0 s, 0 of 141 re-centres blocked. Worst: -10.4 bp on 30 Oct 11:58 and 12:02 UTC.
Spec-literal orientation:
| maxPoolOracleDevBps | events | distinct minutes | longest episode | re-centres blocked of 141 |
| --- | --- | --- | --- | --- |
| 30 | 1,469 | 479 | 59,671 s | 30 (up to 58,332 s) |
| 40 | 68 | 9 | 257 s | 2 (up to 197 s) |
| 50 | 0 | 0 | 0 | 0 (max 49.45 bp, 0.55 bp from tripping) |
| 60, 80, 100 | 0 | 0 | 0 | 0 |
Leg band, time outside 1 +- band: USDC never at 20/30/50/100; USDT at 20: once, 59,671 s (22.1 bp); never at 30/50/100. Max deviation USDC 4.25 bp, USDT 22.09 bp. "Never" holds for 30 and above only; 30 leaves 8 bp and would have latched USDT 3 times since April 2023.

## 3. Depegs seen by these feeds (MEASURED; market side DOCUMENTED by press, market-to-feed lag NOT measured, ESTIMATED minutes)
- USDC, SVB, 10 to 14 Mar 2023: feed 0.99884 at 21:56 UTC, 22:28 first beyond 20 bp, **50 bp at 00:38 (2 h 10 min later), 100 bp at 01:57, minimum 0.88043 at 07:50 on 11 Mar** (-1,196 bp); 1,089 rounds, median gap 60 s in the first 12 h; more than 50 bp off for 2.5 days. USDT moved the other way, +154 bp, 50 bp at 01:00.
- USDT, UST, 11 to 13 May 2022: minimum 0.95153 (-485 bp); 50 bp about 8.8 h after the first 20 bp. USDC +287 bp upward spike the same days.
- USDT, FTX, 9 to 10 Nov 2022: minimum 0.98315 (-168 bp); 50 bp 42 min after the first 20 bp.
- One-sided flashes above 50 bp: USDC +56 (Dec 2021), +59 (May and Aug 2022), +67 (Nov 2022); USDT +68 (Dec 2021), +56 (Jan 2024, 79 s in force), **+66 (10 Oct 2025, 1,045 s in force, current aggregator family)**. Since then no excursion over 50 bp (USDT 22 bp in Feb and Oct 2026).
The current aggregator (since 3 Aug 2026) has never seen a depeg; its stress cadence is the documented 0.1 % rule, not measured. During the 10 Oct 2025 event the then-current feed gave 30 rounds in 2 h (median gap 91 s).
Would defaults have tripped? Yes for every real depeg: band 50 trips 2 h 10 min after the first sign on USDC March 2023, after about 56 bp of USDC loss had printed (unfavourable), and about 7 h before the bottom. Staleness 26 h never trips on a live feed (no gap above 24.03 h in 7,154 rounds); it only fires on a broken feed. Unfavourable: 50 bp also latches on flashes, 2 times since April 2023 (USDT Jan 2024, USDT Oct 2025); 75 bp avoids all flashes (largest 67.6 bp) and delays a March-2023 trip by about 40 min (50 to 75 bp: 00:38 to 01:18). Counts of excursions per threshold in `band_latch_counts.json` are not monotonic because of the 6 h merge rule.

## 4. Rebalance caps (3-bin P1, reproduced from the same series, not independent)
141 re-centres in 30 days. Per UTC day: **max 32 (30 Oct), p90 6, median 4**, mean 4.7; per UTC hour max 9; rolling 24 h max 35; rolling 1 h max 15. Cap 48 refuses 0; cap 32 refuses 0; 24 refuses 8; 16 refuses 16. 5-bin max 18 a day; active-bin-only 1,443 re-centres, max 103 a day.
Cooldown (DERIVED): 120 s delays 7 of 141, longest 88 s, 274 s total; 111 s delays 6 (the gaps under the forfeiture window); 300 s delays 20 (longest 1,247 s); 600 s delays 24 (longest 5,242 s). Smallest gap between wanted re-centres 65 s.

## 5. Recommendation
| parameter | spec | recommended | basis |
| --- | --- | --- | --- |
| legBandBps | 50 | 50 (75 if one false latch per 2 years is unacceptable) | window max 22.1 bp; 20 and 30 unsafe; 50 latched twice on flashes since Apr 2023; all real depegs exceeded it |
| maxFeedAge | 93,600 | 93,600 | heartbeat 86,400; max age ever 86,495 s; margin 7,105 s |
| maxPoolOracleDevBps | 60 | 60, orientation fixed to tokenX/tokenY | correct max 10.4 bp; literal max 49.45 bp (50 and below unsafe) |
| rebalanceCooldown | 120 | 120 | 7 of 141 delayed, max 88 s; must stay above 111 |
| maxRebalancesPerDay | 48 | 48 | max 32 UTC, 35 rolling, median 4 |
| maxSwapBps | 6,000 | 6,000 (ESTIMATED) | an even 3-bin split from a single-asset position needs between 1/3 and 2/3 of NAV swapped depending on the active-bin fill; 6,000 sits inside that range; not computed from replayed bin composition |
| maxRebalanceLossBps | 50 | 50 | swap-leg bound (oracle-implied out minus 50 bp) is tighter than bit 16 at 60: a pool 50 to 60 bp from oracle blocks the swap before bit 16 does (fail-closed; correct-orientation max is 10.4 bp so it is not binding); NAV loss at 60 % swap and 60 bp gap is 36 bp, below 50; no data to justify tightening |
Disagreements with the spec text: bit-16 orientation; "feed noise 10 bp" should be 22 bp (30 days) up to 37 bp (history), so 50 is a 2.3x margin over the window maximum, not 5x; "pool discount 11 bp" is mostly the USDT feed. The cap 48, cooldown 120 and the "max 32, median 4" figure reproduce.
