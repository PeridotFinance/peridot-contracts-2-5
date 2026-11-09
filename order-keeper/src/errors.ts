// Classification of a reverted simulation. The order stays open in every case; the class decides the cooldown and whether a human is told.
//   wait       : the normal ways an order is not fillable right now (trigger not reached, oracle unavailable, registry paused, the close path refused on
//                price or slippage, the pool cannot fill within the floor). Short, doubling cooldown; no alert until it has lasted `unfilledAlertSeconds`.
//   final      : the order is no longer open (another keeper or the owner was first, or a sibling executed): dropped, no cooldown.
//   attention  : a revert nobody classified. Long cooldown and a warning: a person should look.
import { utils } from "ethers";
import { ADAPTER_ABI, EXECUTOR_ABI, REGISTRY_ABI, SWAP_ERRORS_ABI } from "./abi";

const errIface = new utils.Interface([...REGISTRY_ABI.filter((f) => f.startsWith("error ")), ...ADAPTER_ABI.filter((f) => f.startsWith("error ")), ...SWAP_ERRORS_ABI, "error ExecutorError(uint8 code)", "error PriceUnavailable(address asset)"]);
void EXECUTOR_ABI;

export type RevertKind = "wait" | "final" | "attention";
export interface RevertClass {
  kind: RevertKind;
  name: string;
  detail: string;
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
    if (/rate.?limit|429|timeout|network|ECONN|ETIMEDOUT|SERVER_ERROR|header not found/i.test(msg)) return { kind: "wait", name: "endpoint", detail: "the endpoint failed or limited the simulation; nothing was sent" };
    return { kind: "attention", name: "no-revert-data", detail: "the simulation failed without revert data" };
  }
  const sel = data.slice(0, 10).toLowerCase();
  if (sel === "0x08c379a0") {
    try {
      const [reason] = utils.defaultAbiCoder.decode(["string"], "0x" + data.slice(10));
      // the router's minimum-output check ("Too little received", measured on the fork when the oracle is 2 % above what the pool pays): the pool cannot fill within the floor
      if (/^too little received$/i.test(String(reason))) return { kind: "wait", name: "Error", detail: "Too little received (the pool pays less than the minimum)" };
      return { kind: "attention", name: "Error", detail: String(reason).slice(0, 120) };
    } catch {
      return { kind: "attention", name: "Error", detail: "undecodable revert string" };
    }
  }
  if (sel === "0x4e487b71") return { kind: "attention", name: "Panic", detail: data.slice(0, 74) };
  let parsed: { name: string; args: utils.Result };
  try {
    const frag = errIface.getError(sel);
    parsed = { name: frag.name, args: errIface.decodeErrorResult(frag, data) };
  } catch {
    return { kind: "attention", name: "unknown", detail: `selector ${sel}` };
  }
  const code = parsed.args[0] !== undefined && typeof parsed.args[0] !== "object" ? Number(parsed.args[0].toString()) : undefined;
  switch (parsed.name) {
    case "TriggerNotReached":
    case "OracleUnavailable":
    case "ExecutionPaused":
    case "InsufficientOutput":
    case "PriceUnavailable":
      return { kind: "wait", name: parsed.name, detail: "" };
    case "InvalidClose": // adapter: 5 close fee above the 1 % cap, 6 price moved between the registry's check and the close
      return code === 5 || code === 6 ? { kind: "wait", name: `InvalidClose(${code})`, detail: code === 5 ? "close fee above the cap" : "oracle price moved" } : { kind: "attention", name: `InvalidClose(${code})`, detail: "inconsistent inputs from the registry" };
    case "SwapError": // 5: the minimum looser than the swap module's protocol floor (pool and oracle further apart than the pair allows); 7: pool paid less than the floor
      return code === 5 || code === 7 ? { kind: "wait", name: `SwapError(${code})`, detail: code === 5 ? "minimum looser than the protocol floor (oracle and pool too far apart)" : "pool paid less than the floor" } : { kind: "attention", name: `SwapError(${code})`, detail: "" };
    case "OrderNotOpen":
      return { kind: "final", name: "OrderNotOpen", detail: "" };
    default:
      return { kind: "attention", name: parsed.name + (code !== undefined ? `(${code})` : ""), detail: "" };
  }
}
