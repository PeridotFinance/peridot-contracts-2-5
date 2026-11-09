// Copied from operator/src/logpace.ts. The keeper's order discovery never depends on logs; this paces the OPTIONAL log cross-check only.
// Pacing and back-off for every eth_getLogs call that goes to the LOG endpoint (the Avalanche public RPC by default). MEASURED 9 Nov 2026: that endpoint
// refuses ranges over 100 blocks and answers HTTP 429 (Cloudflare 1015) to a burst of requests; ethers retries 429 silently with growing waits (a 13-minute
// hang in the first live check), so the log provider is built with throttleLimit 1 and THIS module spaces the requests and backs off after a 429.
//   * minIntervalMs between two requests (default 0 here so tests are fast; main.ts sets 300 ms);
//   * after a rate-limit answer, no request is sent for `backoff` seconds (60 s, doubling to 900 s, reset by the next success): callers get an error at once
//     and treat it like any failing log endpoint (the index finding `index:behind`, the keeper does not pay because it cannot verify its own spend).
import type { providers } from "ethers";

let minIntervalMs = 0;
let last = 0;
let backoffUntil = 0;
let backoffSeconds = 0;
let clock: () => number = () => Date.now();
const BACKOFF_FIRST_S = 60;
const BACKOFF_MAX_S = 900;

export class LogRateLimitedError extends Error {}

export function configureLogPace(opts: { minIntervalMs?: number; now?: () => number }): void {
  if (opts.minIntervalMs !== undefined) minIntervalMs = opts.minIntervalMs;
  if (opts.now) clock = opts.now;
  last = 0;
  backoffUntil = 0;
  backoffSeconds = 0;
}

export function isRateLimit(err: unknown): boolean {
  const m = String((err as { message?: string; body?: string; status?: number })?.message ?? err) + String((err as { body?: string })?.body ?? "") + String((err as { status?: number })?.status ?? "");
  return /\b429\b|1015|rate.?limit|too many requests|exceeded.*(rate|capacity)/i.test(m);
}

export function logBackoffRemainingSeconds(): number {
  return Math.max(0, Math.ceil((backoffUntil - clock()) / 1000));
}

export async function pacedGetLogs(provider: providers.Provider, filter: providers.Filter): Promise<providers.Log[]> {
  const now = clock();
  if (now < backoffUntil) throw new LogRateLimitedError(`the log endpoint rate-limited us; no request for another ${logBackoffRemainingSeconds()} s`);
  const wait = last + minIntervalMs - now;
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  last = clock();
  try {
    const logs = await provider.getLogs(filter);
    backoffSeconds = 0;
    return logs;
  } catch (err) {
    if (isRateLimit(err)) {
      backoffSeconds = backoffSeconds === 0 ? BACKOFF_FIRST_S : Math.min(BACKOFF_MAX_S, backoffSeconds * 2);
      backoffUntil = clock() + backoffSeconds * 1000;
      throw new LogRateLimitedError(`the log endpoint answered 429 (rate limit); backing off ${backoffSeconds} s`);
    }
    throw err;
  }
}
