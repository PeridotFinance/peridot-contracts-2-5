// `dlmm-keeper preflight`: READ-ONLY checks that need NO vault (and, when the configuration names a deployed vault, the wiring check too). Prints PASS / FAIL / INFO lines
// and the caller exits non-zero on any FAIL. Nothing is signed or sent; the endpoint is never printed (the caller passes every line through mask()).
import { utils } from "ethers";
import type { providers } from "ethers";
import { batch, checkWiring, pairIface, pairQuote } from "./chain";
import type { Check } from "./chain";
import type { KeeperConfig } from "./config";
import { ERC20_ABI, FEED_ABI } from "./abi";
import { legBandBpsOf, oraclePrice18, pool18 } from "./sanity";
import type { FeedReading } from "./sanity";

const feedIface = new utils.Interface(FEED_ABI);
const erc20Iface = new utils.Interface(ERC20_ABI);
const bi = (v: unknown): bigint => BigInt(String(v));
const PEG_ID = 1 << 23;
/** the vault's default guard numbers (the deploy uses these): the keeper uses the stricter of its own and these */
const VAULT_DEFAULTS = { legBandBps: 50, maxFeedAge: 93_600, maxPoolOracleDevBps: 60 };

export async function preflight(provider: providers.Provider, cfg: KeeperConfig, nowS: number, vaultKnown: boolean): Promise<Check[]> {
  const out: Check[] = [];
  const add = (level: Check["level"], text: string): void => void out.push({ level, text });
  // ---- RPC, head block, gas
  const blk = await provider.getBlock("latest");
  const lag = nowS - blk.timestamp;
  add(lag <= cfg.timing.maxBlockLagSeconds ? "PASS" : "FAIL", `RPC reachable; head block ${blk.number}, ${lag} s old (limit ${cfg.timing.maxBlockLagSeconds} s)`);
  const fd = await provider.getFeeData();
  const price = fd.gasPrice ?? fd.maxFeePerGas;
  if (price) {
    const perReb = price.mul(cfg.limits.gasPerRebalance);
    add(price.lte(utils.parseUnits(String(cfg.limits.maxFeeGwei), "gwei")) ? "PASS" : "FAIL", `gas price ${utils.formatUnits(price, "gwei")} gwei (cap ${cfg.limits.maxFeeGwei}); one rebalance at ${cfg.limits.gasPerRebalance} gas = ${utils.formatEther(perReb)} AVAX; ${cfg.limits.minRebalancesCovered} rebalances = ${utils.formatEther(perReb.mul(cfg.limits.minRebalancesCovered))} AVAX (the runway-alert level)`);
  } else add("FAIL", "no gas price from the node");
  // ---- pair, tokens
  const P = cfg.pair;
  const r = await batch(provider, cfg.multicall3, [
    { target: P, iface: pairIface, fn: "getTokenX" }, // 0
    { target: P, iface: pairIface, fn: "getTokenY" }, // 1
    { target: P, iface: pairIface, fn: "getBinStep" }, // 2
    { target: P, iface: pairIface, fn: "getActiveId" }, // 3
    { target: cfg.assetToken, iface: erc20Iface, fn: "decimals" }, // 4
    { target: cfg.pairToken, iface: erc20Iface, fn: "decimals" }, // 5
    { target: cfg.feeds.asset, iface: feedIface, fn: "latestRoundData" }, // 6
    { target: cfg.feeds.asset, iface: feedIface, fn: "decimals" }, // 7
    { target: cfg.feeds.pair, iface: feedIface, fn: "latestRoundData" }, // 8
    { target: cfg.feeds.pair, iface: feedIface, fn: "decimals" }, // 9
    { target: P, iface: pairIface, fn: "getLBHooksParameters" }, // 10
  ]);
  const v = (i: number, k = 0): unknown => (r[i]?.success && r[i]!.value ? r[i]!.value![k] : undefined);
  const tx = v(0) as string | undefined;
  const ty = v(1) as string | undefined;
  if (!tx || !ty) return [...out, { level: "FAIL", text: `pair ${P}: getTokenX/getTokenY failed (is it the pair?)` }];
  const orientOk = (tx.toLowerCase() === cfg.pairToken.toLowerCase() && ty.toLowerCase() === cfg.assetToken.toLowerCase()) || (tx.toLowerCase() === cfg.assetToken.toLowerCase() && ty.toLowerCase() === cfg.pairToken.toLowerCase());
  add(orientOk ? "PASS" : "FAIL", `pair tokens X=${tx} Y=${ty}; configured asset ${cfg.assetToken}, pair token ${cfg.pairToken}`);
  add(Number(v(2)) === 1 ? "PASS" : "FAIL", `bin step ${String(v(2))}`);
  const decA = Number(v(4));
  const decP = Number(v(5));
  add(decA === 6 && decP === 6 ? "PASS" : "FAIL", `token decimals asset ${decA}, pair token ${decP}`);
  const active = Number(v(3));
  add(Math.abs(active - PEG_ID) <= 20 ? "PASS" : "FAIL", `pair active id ${active} (${active - PEG_ID >= 0 ? "+" : ""}${active - PEG_ID} bins from the peg bin 2^23; normal range about -10 to 0)`);
  // ---- hook (the exit path's dependency)
  const hp = v(10) as string | undefined;
  if (hp) {
    const hook = "0x" + BigInt(hp).toString(16).padStart(64, "0").slice(24);
    add(/^0x0{40}$/.test(hook) ? "FAIL" : "INFO", `pair hook ${utils.getAddress(hook)} (every burn, hence every exit, calls it; the keeper's exit probe watches it once a vault holds a band)`);
  } else add("INFO", "pair.getLBHooksParameters() not readable");
  // ---- feeds and the keeper's own oracle check
  const feed = (ri: number, di: number): FeedReading | undefined => {
    if (!r[ri]?.success || !r[ri]!.value || !r[di]?.success) return undefined;
    const x = r[ri]!.value!;
    return { roundId: bi(x[0]), answer: bi(x[1]), updatedAt: Number(bi(x[3])), answeredInRound: bi(x[4]), decimals: Number(r[di]!.value![0]) };
  };
  const fA = feed(6, 7);
  const fP = feed(8, 9);
  if (!fA || !fP) add("FAIL", "a Chainlink feed could not be read");
  else {
    const legLimit = Math.min(cfg.rebalance.keeperLegBandBps, VAULT_DEFAULTS.legBandBps);
    for (const [name, f, addr] of [["USDC/USD", fA, cfg.feeds.asset], ["USDT/USD", fP, cfg.feeds.pair]] as const) {
      const age = blk.timestamp - f.updatedAt;
      add(f.decimals === 8 ? "PASS" : "FAIL", `${name} feed ${addr}: decimals ${f.decimals}`);
      add(f.answer > 0n && legBandBpsOf(f) <= legLimit ? "PASS" : "FAIL", `${name} answer ${f.answer} = ${legBandBpsOf(f)} bp from 1.00 (depeg band: keeper ${cfg.rebalance.keeperLegBandBps} bp, vault default ${VAULT_DEFAULTS.legBandBps} bp; the stricter applies = ${legLimit} bp)`);
      add(age <= VAULT_DEFAULTS.maxFeedAge && f.answeredInRound >= f.roundId ? "PASS" : "FAIL", `${name} age ${age} s (vault maxFeedAge ${VAULT_DEFAULTS.maxFeedAge} s), round complete=${f.answeredInRound >= f.roundId}`);
    }
    // pool price at the active id against the oracle ratio (X leg = the pair's token X)
    const assetIsX = tx.toLowerCase() === cfg.assetToken.toLowerCase();
    const feedX = assetIsX ? fA : fP;
    const feedY = assetIsX ? fP : fA;
    try {
      const pr = await batch(provider, cfg.multicall3, [{ target: P, iface: pairIface, fn: "getPriceFromId", args: [active] }]);
      const p18 = pool18(bi(pr[0]!.value![0]));
      const o18 = oraclePrice18(feedX, feedY, assetIsX ? decA : decP, assetIsX ? decP : decA);
      const dev = Number(((p18 > o18 ? p18 - o18 : o18 - p18) * 10_000n) / o18);
      const lim = Math.min(cfg.rebalance.maxPoolOracleDevBps, VAULT_DEFAULTS.maxPoolOracleDevBps);
      add(dev <= lim ? "PASS" : "FAIL", `pool price at the active id vs the oracle ratio: ${dev} bp apart (keeper ${cfg.rebalance.maxPoolOracleDevBps} bp, vault default ${VAULT_DEFAULTS.maxPoolOracleDevBps} bp; limit ${lim} bp)`);
    } catch (e) {
      add("FAIL", `pool price / oracle comparison failed: ${(e as Error).message.slice(0, 120)}`);
    }
  }
  // ---- the exit probe's pair reads (the same three calls per bin the probe makes) and the quote the sizing uses
  try {
    const ids = [active - 1, active, active + 1];
    const calls = ids.flatMap((id) => [
      { target: P, iface: pairIface, fn: "totalSupply", args: [id] },
      { target: P, iface: pairIface, fn: "getBin", args: [id] },
    ]);
    const br = await batch(provider, cfg.multicall3, calls);
    add(br.every((x) => x.success) ? "PASS" : "FAIL", `exit-probe pair reads: totalSupply/getBin of bins ${ids.join(", ")} ok (${br.filter((x) => x.success).length}/${br.length})`);
  } catch (e) {
    add("FAIL", `exit-probe pair reads failed: ${(e as Error).message.slice(0, 120)}`);
  }
  try {
    const q = pairQuote(provider, cfg, "latest");
    const assetIsX = tx.toLowerCase() === cfg.assetToken.toLowerCase();
    const a = await q(!assetIsX, 100_000_000n); // 100 pair token -> asset
    const b = await q(assetIsX, 100_000_000n); // 100 asset -> pair token
    const okq = a.amountInLeft === 0n && b.amountInLeft === 0n && a.amountOut > 99_000_000n && b.amountOut > 99_000_000n;
    add(okq ? "PASS" : "FAIL", `quote (getSwapOut) of 100 units each way: pair token -> asset ${a.amountOut} (left ${a.amountInLeft}), asset -> pair token ${b.amountOut} (left ${b.amountInLeft})`);
  } catch (e) {
    add("FAIL", `getSwapOut quote failed: ${(e as Error).message.slice(0, 120)}`);
  }
  // ---- the vault (only when the configuration names one)
  if (vaultKnown) out.push(...(await checkWiring(provider, cfg)));
  else add("INFO", "vault: not wired yet (the configuration still carries the placeholder): wiring is checked by the `wire` step once the operator has deployed it");
  return out;
}
