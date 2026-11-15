// Classification of a reverted simulation or transaction (the vault's custom errors, decoded). The keeper NEVER loops on a revert: every class sets a backoff.
//   halt      : GuardLatched, or GuardUnsafe with a latchable bit (1,2,4,8): the keeper stops sending (HALT file)
//   benign    : the world moved, nothing is wrong (NotOutOfRange: the active bin returned; CooldownActive; DailyRebalanceCapReached; GuardUnsafe with only the live bits 16/32)
//   retry     : ActiveIdMoved (one adaptive re-simulation with the reported id, then an ordinary failure)
//   failure   : counted (NavLossTooLarge, SwapTooLarge, anything unclassified): backoff doubling, alert, counts toward maxConsecutiveFailures
//   endpoint  : the node failed or limited the call: not the vault's fault, not counted as a failure of the vault logic, backoff
import { utils } from "ethers";
import { VAULT_ABI } from "./abi";
import { LATCHABLE_MASK, bitNames } from "./constants";

const errIface = new utils.Interface(VAULT_ABI.filter((f) => f.startsWith("error ")));
export type RevertKind = "halt" | "benign" | "retry" | "failure" | "endpoint";
export interface RevertClass {
  kind: RevertKind;
  name: string;
  detail: string;
  /** ActiveIdMoved.actual */
  actualId?: number;
  /** CooldownActive.readyAt */
  readyAt?: number;
  reasons?: number;
}

/** Revert data (0x...) out of whatever shape ethers v5 or a JSON-RPC node put it in. */
export function revertData(err: unknown): string | undefined {
  const seen = new Set<unknown>();
  const walk = (e: any, depth: number): string | undefined => {
    if (!e || typeof e !== "object" || depth > 6 || seen.has(e)) return undefined;
    seen.add(e);
    for (const k of ["data", "errorArgs"]) {
      const v = e[k];
      if (typeof v === "string" && /^0x([0-9a-fA-F]{8})([0-9a-fA-F]{2})*$/.test(v)) return v;
      if (v && typeof v === "object") {
        const r = walk(v, depth + 1);
        if (r) return r;
      }
    }
    if (typeof e.body === "string") {
      try {
        const r = walk(JSON.parse(e.body), depth + 1);
        if (r) return r;
      } catch {
        /* not JSON */
      }
    }
    for (const k of ["error", "result", "response"]) {
      const r = walk(e[k], depth + 1);
      if (r) return r;
    }
    return undefined;
  };
  const found = walk(err, 0);
  if (found) return found;
  const m = String((err as { message?: string })?.message ?? err).match(/0x08c379a0[0-9a-fA-F]+|0x[0-9a-fA-F]{8}(?:[0-9a-fA-F]{64})*(?![0-9a-fA-F])/);
  return m ? m[0] : undefined;
}

export function classifyRevert(err: unknown): RevertClass {
  const data = revertData(err);
  if (!data) {
    const msg = String((err as { message?: string })?.message ?? err);
    if (/rate.?limit|429|timeout|network|ECONN|ETIMEDOUT|SERVER_ERROR|header not found/i.test(msg)) return { kind: "endpoint", name: "endpoint", detail: "the endpoint failed or limited the call; nothing was sent" };
    return { kind: "failure", name: "no-revert-data", detail: "the simulation failed without revert data" };
  }
  const sel = data.slice(0, 10).toLowerCase();
  if (sel === "0x08c379a0") {
    try {
      const [reason] = utils.defaultAbiCoder.decode(["string"], "0x" + data.slice(10));
      return { kind: "failure", name: "Error", detail: String(reason).slice(0, 120) };
    } catch {
      return { kind: "failure", name: "Error", detail: "undecodable revert string" };
    }
  }
  if (sel === "0x4e487b71") return { kind: "failure", name: "Panic", detail: data.slice(0, 74) };
  let name: string;
  let args: utils.Result;
  try {
    const frag = errIface.getError(sel);
    name = frag.name;
    args = errIface.decodeErrorResult(frag, data);
  } catch {
    return { kind: "failure", name: "unknown", detail: `selector ${sel}` };
  }
  const n = (i: number): number => Number(args[i]?.toString() ?? 0);
  switch (name) {
    case "GuardLatched":
      return { kind: "halt", name, detail: "the vault guard is latched" };
    case "GuardUnsafe": {
      const reasons = n(0);
      return (reasons & LATCHABLE_MASK) !== 0 ? { kind: "halt", name, detail: bitNames(reasons), reasons } : { kind: "benign", name, detail: `live only: ${bitNames(reasons)}`, reasons };
    }
    case "NotOutOfRange":
      return { kind: "benign", name, detail: "the active bin is inside the band again" };
    case "CooldownActive":
      return { kind: "benign", name, detail: `ready at ${n(0)}`, readyAt: n(0) };
    case "DailyRebalanceCapReached":
      return { kind: "benign", name, detail: "the vault's daily rebalance cap is reached" };
    case "ActiveIdMoved":
      return { kind: "retry", name, detail: `expected ${n(0)}, actual ${n(1)}, slippage ${n(2)}`, actualId: n(1) };
    default:
      return { kind: "failure", name, detail: args.length ? Array.from(args).map(String).join(",").slice(0, 120) : "" };
  }
}
