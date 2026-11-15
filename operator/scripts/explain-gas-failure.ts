// Causal check of the one failed transaction in the vault-opening rehearsal: the SAME transaction (deployIdle after a team-seed deposit) sent with the node's
// raw gas estimate, then with margins on top of it, from the SAME state (evm_snapshot before each attempt). Shows whether the failure is the gas limit.
//   AVALANCHE_MAINNET_RPC_URL=... node dist/scripts/explain-gas-failure.js <forkBlock> [--out report.json]
import fs from "node:fs";
import { BigNumber, Contract, utils } from "ethers";
import { ForkChain } from "../test/fork/harness";

const LEDGER = "0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD";
const SAFE = "0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12";
const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
const V = "0x855bF832f26a294d28500db59eE941dE3d654129";
const vaultAbi = ["function deposit(uint256,address) returns (uint256)", "function deployIdle()", "function setDepositCap(uint256)"];
const erc = ["function approve(address,uint256) returns (bool)"];
const safeAbi = ["function execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) returns (bool)"];

(async () => {
  const block = Number(process.argv[2]);
  const chain = await ForkChain.start(block);
  const rep: any = { forkBlock: block, attempts: [] };
  try {
    await chain.setBalance(LEDGER, utils.parseEther("10"));
    const led = chain.signer(LEDGER);
    const sig = utils.hexConcat([utils.hexZeroPad(LEDGER, 32), utils.hexZeroPad("0x00", 32), "0x01"]);
    const z = "0x0000000000000000000000000000000000000000";
    const data = new utils.Interface(vaultAbi).encodeFunctionData("setDepositCap", [BigNumber.from("5000000000")]);
    await (await new Contract(SAFE, safeAbi, led).execTransaction(V, 0, data, 0, 0, 0, 0, z, z, sig, { gasLimit: 500_000 })).wait();
    await chain.setErc20Balance(USDC, LEDGER, BigNumber.from(500_000_000));
    await (await new Contract(USDC, erc, led).approve(V, 500_000_000, { gasLimit: 120_000 })).wait();
    await (await new Contract(V, vaultAbi, led).deposit(500_000_000, LEDGER, { gasLimit: 3_000_000 })).wait();
    const vault: any = new Contract(V, vaultAbi, led);
    const est: BigNumber = await vault.estimateGas.deployIdle();
    rep.rawEstimate = est.toString();
    // the estimate is taken NOW; the transaction executes in a LATER block (k seconds later): the gas of the oracle (TWAP) reads and of the fee collection depends on the time
    for (const [pct, delay] of [[100, 0], [100, 1], [100, 3], [100, 10], [100, 60], [100, 600], [105, 60], [110, 60], [125, 60], [125, 600]] as const) {
      const snap = await chain.snapshot();
      const limit = est.mul(pct).div(100);
      if (delay > 0) await chain.send("evm_setNextBlockTimestamp", [(await chain.now()) + delay]);
      let status: string;
      let used = "";
      try {
        const rc = await (await vault.deployIdle({ gasLimit: limit })).wait();
        status = "ok";
        used = rc.gasUsed.toString();
      } catch (e: any) {
        status = "REVERTED";
        const h = e?.transactionHash;
        if (h) used = (await chain.provider.getTransactionReceipt(h)).gasUsed.toString();
      }
      rep.attempts.push({ delaySeconds: delay, marginPercent: pct - 100, gasLimit: limit.toString(), status, gasUsed: used });
      await chain.revert(snap);
    }
  } catch (e) {
    rep.error = String((e as Error).message).slice(0, 200);
  } finally {
    await chain.stop();
  }
  const i = process.argv.indexOf("--out");
  const text = JSON.stringify(rep, null, 2);
  if (i >= 0) fs.writeFileSync(process.argv[i + 1]!, text + "\n");
  console.log(text);
  process.exit(0);
})();
