// Batched read-only calls through Multicall3 (deployed at the same address on Avalanche C-Chain), always at ONE explicit block.
// The batch runs as a single eth_call, so state changes inside it (the markets' `accrueInterest`) are visible to the later calls of the
// same batch, exactly as inside the reference detector's transaction ("it accrues interest on every listed market first, then reads only
// existing views"). Nothing is ever sent: this module has no signer and uses `provider.call` only.
import { providers, utils } from "ethers";
import { MULTICALL3 } from "./constants";
import { MULTICALL3_ABI } from "./abi";

const mcIface = new utils.Interface(MULTICALL3_ABI);

export interface Call {
  target: string;
  iface: utils.Interface;
  fn: string;
  args?: readonly unknown[];
  /** default true: a reverting call must not fail the whole batch (it is reported as success=false and the caller fails closed) */
  allowFailure?: boolean;
}
export interface CallResult {
  success: boolean;
  /** decoded return values when success */
  value?: utils.Result;
  raw: string;
}

export async function multicall(provider: providers.Provider, calls: Call[], blockNumber: number, mcAddress: string = MULTICALL3): Promise<CallResult[]> {
  if (calls.length === 0) return [];
  const data = mcIface.encodeFunctionData("aggregate3", [calls.map((c) => ({ target: c.target, allowFailure: c.allowFailure ?? true, callData: c.iface.encodeFunctionData(c.fn, c.args ?? []) }))]);
  const out = await provider.call({ to: mcAddress, data }, blockNumber);
  const decoded = mcIface.decodeFunctionResult("aggregate3", out)[0] as Array<{ success: boolean; returnData: string }>;
  if (decoded.length !== calls.length) throw new Error("multicall: result length mismatch");
  return decoded.map((r, i) => {
    const c = calls[i]!;
    if (!r.success) return { success: false, raw: r.returnData };
    try {
      return { success: true, value: c.iface.decodeFunctionResult(c.fn, r.returnData), raw: r.returnData };
    } catch {
      return { success: false, raw: r.returnData }; // malformed return data = failed call (fail closed)
    }
  });
}

/** Convenience: decoded first return value as bigint, or undefined when the call failed. */
export function big(r: CallResult | undefined, idx = 0): bigint | undefined {
  if (!r || !r.success || !r.value) return undefined;
  const v = r.value[idx];
  return v === undefined ? undefined : BigInt(v.toString());
}
