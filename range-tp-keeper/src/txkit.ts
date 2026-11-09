// COPIED from operator/src (no runtime import from operator/).
// Small shared transaction helper for the executor: fee cap, gas floor, send-and-wait with a distinguishable "mined but reverted" error.
// (The treasury keeper has its own equivalent inline; it is left untouched.) Holds no key: it only calls the ExternalSigner.
import { BigNumber, providers, utils } from "ethers";
import type { ExternalSigner, TxRequest } from "./signer";

export const TX_WAIT_TIMEOUT_MS = 180_000;
export class TxReverted extends Error {
  constructor(public readonly hash: string) {
    super(`transaction ${hash} was mined and reverted`);
  }
}

export interface Fees {
  maxFeePerGas: BigNumber;
  maxPriorityFeePerGas: BigNumber;
}
export async function feesWithin(provider: providers.Provider, maxFeeGwei: number): Promise<{ ok: true; fees: Fees } | { ok: false; reason: string }> {
  const fee = await provider.getFeeData();
  const maxFee = fee.maxFeePerGas ?? fee.gasPrice;
  if (!maxFee) return { ok: false, reason: "no fee data" };
  if (maxFee.gt(utils.parseUnits(String(maxFeeGwei), "gwei"))) return { ok: false, reason: `max fee ${utils.formatUnits(maxFee, "gwei")} gwei is above the cap ${maxFeeGwei} gwei` };
  let priority = fee.maxPriorityFeePerGas ?? utils.parseUnits("1", "gwei");
  if (priority.gt(maxFee)) priority = maxFee;
  return { ok: true, fees: { maxFeePerGas: maxFee, maxPriorityFeePerGas: priority } };
}

export function makeSender(signer: ExternalSigner, fees: Fees): (to: string, data: string, gasLimit: BigNumber) => Promise<{ hash: string; blockNumber: number; gasUsed: BigNumber }> {
  return async (to, data, gasLimit) => {
    const tx: TxRequest = { to, data, gasLimit, ...fees };
    const sent = await signer.sendTransaction(tx);
    let mined;
    let timer: NodeJS.Timeout | undefined;
    try {
      // a stalled wait must not hang the process between transactions: the caller treats the timeout as unexpected, keeps the pending marker and halts
      // (CHANGED from the operator's copy: the timer is cleared when the wait ends, otherwise it keeps the process alive for 180 s after a send;
      // found when the fork test held the shared fork lock for three minutes after it had passed)
      mined = await Promise.race([sent.wait(), new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new Error(`transaction ${sent.hash} was not mined within ${TX_WAIT_TIMEOUT_MS / 1000} s`)), TX_WAIT_TIMEOUT_MS); })]);
    } catch (e) {
      // ethers v5 rejects wait() with CALL_EXCEPTION when the transaction was mined with status 0
      if ((e as { code?: string }).code === "CALL_EXCEPTION") throw new TxReverted(sent.hash);
      throw e;
    }
    finally {
      if (timer) clearTimeout(timer);
    }
    if (mined.status !== 1) throw new TxReverted(sent.hash);
    return { hash: sent.hash, blockNumber: mined.blockNumber, gasUsed: mined.gasUsed };
  };
}
