// Configuration: public values only (addresses, limits). The RPC endpoint and the keystore password come from the ENVIRONMENT, by the variable
// names given here; they are never in this file, never printed, never in the state.
import fs from "node:fs";
import { utils } from "ethers";
import { DEFAULT_LIMITS, KeeperLimits } from "./keeper";

export interface KeeperConfig {
  chainId: number;
  custodian: string;
  rpcEnv: string;
  /** optional separate endpoint for eth_getLogs (event discovery only); default = the main endpoint */
  logRpcEnv?: string;
  keystore: { path: string; passwordEnv: string };
  statePath: string;
  pollSeconds: number;
  maxFeeGwei: number;
  logChunkBlocks: number;
  logMinIntervalMs: number;
  limits: KeeperLimits;
}

export function parseConfig(json: unknown): KeeperConfig {
  const j = json as Record<string, any>;
  const fail = (m: string): never => {
    throw new Error(`config: ${m}`);
  };
  if (!j || typeof j !== "object") fail("not an object");
  if (j.chainId !== 43114) fail("chainId must be 43114 (Avalanche C-Chain)");
  if (typeof j.custodian !== "string" || !utils.isAddress(j.custodian)) fail("custodian must be an address");
  if (typeof j.rpcEnv !== "string" || !/^[A-Z][A-Z0-9_]+$/.test(j.rpcEnv)) fail("rpcEnv must be the NAME of an environment variable");
  if (j.logRpcEnv !== undefined && (typeof j.logRpcEnv !== "string" || !/^[A-Z][A-Z0-9_]+$/.test(j.logRpcEnv))) fail("logRpcEnv must be the NAME of an environment variable");
  if (!j.keystore || typeof j.keystore.path !== "string" || typeof j.keystore.passwordEnv !== "string" || !/^[A-Z][A-Z0-9_]+$/.test(j.keystore.passwordEnv)) fail("keystore.path and keystore.passwordEnv (an environment variable NAME) are required");
  const num = (k: string, d: number, lo: number, hi: number): number => {
    const v = j[k] === undefined ? d : Number(j[k]);
    if (!Number.isFinite(v) || v < lo || v > hi) fail(`${k} must be within ${lo}..${hi}`);
    return v;
  };
  const l = (j.limits ?? {}) as Record<string, unknown>;
  const lim = (k: keyof KeeperLimits, lo: number, hi: number): number => {
    const v = l[k] === undefined ? Number(DEFAULT_LIMITS[k]) : Number(l[k]);
    if (!Number.isFinite(v) || v < lo || v > hi) fail(`limits.${k} must be within ${lo}..${hi}`);
    return v;
  };
  return {
    chainId: 43114,
    custodian: utils.getAddress(j.custodian),
    rpcEnv: j.rpcEnv,
    logRpcEnv: j.logRpcEnv,
    keystore: { path: j.keystore.path, passwordEnv: j.keystore.passwordEnv },
    statePath: typeof j.statePath === "string" ? j.statePath : "range-keeper-state.json",
    pollSeconds: num("pollSeconds", 20, 5, 3600),
    maxFeeGwei: num("maxFeeGwei", 60, 1, 1000),
    logChunkBlocks: num("logChunkBlocks", 100, 1, 2048),
    logMinIntervalMs: num("logMinIntervalMs", 300, 0, 60_000),
    limits: {
      minGasWei: BigInt(String(l.minGasWei ?? DEFAULT_LIMITS.minGasWei)),
      maxSendsPerStep: lim("maxSendsPerStep", 1, 20),
      cooldownSeconds: lim("cooldownSeconds", 30, 86_400),
      gasMarginPct: lim("gasMarginPct", 100, 300),
      maxReadsPerStep: lim("maxReadsPerStep", 1, 5000),
    },
  };
}
export function loadConfig(file: string): KeeperConfig {
  return parseConfig(JSON.parse(fs.readFileSync(file, "utf8")));
}
export function requireRpcUrl(envName: string, env: NodeJS.ProcessEnv = process.env): string {
  const v = env[envName];
  if (!v) throw new Error(`the environment variable ${envName} is not set (the endpoint is read from the environment only)`);
  return v;
}
