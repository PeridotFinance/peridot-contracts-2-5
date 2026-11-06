import test from "node:test";
import assert from "node:assert/strict";
import { getSqrtRatioAtTick, meanTick, wavaxReferenceFromTick, MIN_TICK, MAX_TICK } from "../src/tickmath";
import { interpretReference } from "../src/reference";
import type { CallResult } from "../src/multicall";
import { utils } from "ethers";
import { poolIface } from "../src/reference";

const P_USDC = 10n ** 30n; // USD 1.00 in the oracle's scale

test("TickMath matches the on-chain library at its fixed points", () => {
  assert.equal(getSqrtRatioAtTick(0), 79228162514264337593543950336n);
  assert.equal(getSqrtRatioAtTick(MIN_TICK), 4295128739n);
  assert.equal(getSqrtRatioAtTick(MAX_TICK), 1461446703485210103287273052203988822378723970342n);
});
test("mean tick floors toward minus infinity, as OracleLibrary does", () => {
  assert.equal(meanTick(0n, -1801n, 1800), -2);
  assert.equal(meanTick(0n, -1800n, 1800), -1);
  assert.equal(meanTick(0n, 1801n, 1800), 1);
  assert.equal(meanTick(0n, 1799n, 1800), 0);
});
test("price from a tick: pool tick -254599 is about 2.5e-? raw -> about USD 8.8 per WAVAX at USD 1.00 USDC", () => {
  const r = wavaxReferenceFromTick(-254599, P_USDC);
  const usd = Number(r) / 1e18;
  assert.ok(usd > 8.5 && usd < 9.1, `got ${usd}`); // the pinned-block pool tick (-254599) corresponds to the pinned AVAX price
  // 1 bp per tick step
  const up = Number(wavaxReferenceFromTick(-254598, P_USDC)) / Number(r);
  assert.ok(Math.abs(up - 1.0001) < 1e-8);
});
const ok = (v: unknown[]): CallResult => ({ success: true, value: v as unknown as utils.Result, raw: "0x" });
const bad: CallResult = { success: false, raw: "0x" };
const liq = (n: bigint) => ok([n]);
const obs = (c0: bigint, c1: bigint) => ok([[c0, c1], [0n, 0n]]);
const base = { poolIdentityOk: true, liquidity: liq(10n ** 12n), observe: obs(0n, -254599n * 1800n), minPoolLiquidity: 10n ** 9n, usdcOraclePrice: P_USDC };
test("reference: ok path", () => {
  const r = interpretReference(base);
  assert.equal(r.status, "ok");
  if (r.status === "ok") assert.equal(r.tick, -254599);
});
test("reference FAILS CLOSED on every listed cause", () => {
  const cases: Array<[string, Parameters<typeof interpretReference>[0]]> = [
    ["pool identity not confirmed", { ...base, poolIdentityOk: false }],
    ["observe reverts (OLD)", { ...base, observe: bad }],
    ["observe missing", { ...base, observe: undefined }],
    ["liquidity call fails", { ...base, liquidity: bad }],
    ["liquidity below the floor", { ...base, liquidity: liq(10n ** 9n - 1n) }],
    ["derived price zero (tick at the bottom of the range and a tiny USDC price)", { ...base, observe: obs(0n, BigInt(MIN_TICK) * 1800n), usdcOraclePrice: 1n }],
    ["USDC oracle price zero", { ...base, usdcOraclePrice: 0n }],
    ["malformed observe", { ...base, observe: ok([[1n], []]) }],
    ["tick out of range", { ...base, observe: obs(0n, BigInt(MAX_TICK + 5) * 1800n) }],
  ];
  for (const [name, args] of cases) assert.equal(interpretReference(args).status, "none", name);
  void poolIface;
});
