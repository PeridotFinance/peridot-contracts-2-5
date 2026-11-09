// FORK TEST of one finalisation by the keeper, on a LOCAL anvil fork (127.0.0.1) of Avalanche at the fixture's pinned block.
// Prerequisites (one fork job at a time on the free-tier endpoint; see docs/deployment-handoffs/avalanche-range-take-profit.md):
//   1. contracts/range-tp/run-fork.sh --match-contract KeeperFixtureDump     (writes contracts/range-tp/fixtures/{fixture,state}.json)
//   2. forge build in contracts/range-tp (for out/MockFeed.sol)
//   3. AVALANCHE_MAINNET_RPC_URL in the environment; the shared lock held:  until mkdir /tmp/pilot-fork.lock ...; npm run test:fork; rmdir ...
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BigNumber, Contract, utils } from "ethers";
import { Alert, Alerts } from "../../src/alerts";
import { DEFAULT_LIMITS, keeperStep } from "../../src/keeper";
import { EthersPort } from "../../src/port";
import { emptyState, KeeperState, loadState, saveState } from "../../src/state";
import { Fork, FIXTURE_DIR, ImpersonatedSigner, MOCK_FEED_ARTIFACT } from "./harness";

const fixtureFile = path.join(FIXTURE_DIR, "fixture.json");
const ready = !!process.env.AVALANCHE_MAINNET_RPC_URL && fs.existsSync(fixtureFile) && fs.existsSync(MOCK_FEED_ARTIFACT);

test("keeper finalises a fully crossed 70/20/10 ladder on a local anvil fork: waits on a stale oracle, sends once, repays first, closes", { skip: ready ? false : "needs AVALANCHE_MAINNET_RPC_URL, the dumped fixture and out/MockFeed (see the header)", timeout: 600_000 }, async () => {
  const fx = JSON.parse(fs.readFileSync(fixtureFile, "utf8"));
  const fork = await Fork.start(fx.forkBlock);
  try {
    const slots = await fork.loadDump(path.join(FIXTURE_DIR, "state.json"));
    process.stdout.write(`replayed ${slots} storage slots at block ${fx.forkBlock}\n`);
    const T: number = fx.timestamp + 30;
    // oracle: mock feeds at the fixture's answers; the AVAX feed starts STALE (older than its 1,200 s maximum age)
    await fork.mockFeed(fx.avaxFeed, BigInt(fx.avaxAnswer8), T - 5_000);
    await fork.mockFeed(fx.usdcFeed, BigInt(fx.usdcAnswer8), T - 5_000);
    await fork.rpc("anvil_setBalance", [fx.keeper, "0x" + (10n ** 18n).toString(16)]);
    await fork.setNextTimestampAndMine(T);

    const provider = fork.provider;
    const signer = new ImpersonatedSigner(provider, fx.keeper);
    const port = new EthersPort(provider, signer, { custodian: fx.custodian, maxFeeGwei: 500, logChunkBlocks: 100 });
    const alerts: Alert[] = [];
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "rtpk-fork-"));
    const stateFile = path.join(dir, "state.json");
    const deps = { port, alerts: new Alerts({ send: async (a: Alert) => void alerts.push(a) }), limits: DEFAULT_LIMITS, persist: (s: KeeperState) => saveState(stateFile, s) };

    const exec = new Contract(fx.executor, ["function positions(uint256) view returns (uint256 id, address owner, address account, address m, address p, address d, uint256 l, uint256 n, uint256 b, uint16 lev, uint8 side, uint8 status)"], provider);
    const pUsdc = new Contract(fx.pUsdc, ["function borrowBalanceStored(address) view returns (uint256)", "function exchangeRateStored() view returns (uint256)"], provider);
    const vault = new Contract(fx.vault, ["function freeBalance(address,address) view returns (uint256)"], provider);
    const erc20 = (a: string) => new Contract(a, ["function balanceOf(address) view returns (uint256)"], provider);
    const pos = await exec.positions(fx.positionId);
    assert.equal(Number(pos.status), 2, "fixture: position ACTIVE");
    const debtBefore: BigNumber = await pUsdc.borrowBalanceStored(pos.account);
    assert.ok(debtBefore.gt(0));
    const fz = await port.finalizable(BigInt(fx.positionId));
    assert.deepEqual(fz, { active: 3, ready: 3 }, "the pool tick has crossed all three rungs");

    // ---- 1. stale oracle: the simulation says OracleUnavailable: a WAIT, nothing sent
    const nonce0 = await provider.getTransactionCount(fx.keeper);
    let st = emptyState();
    let r = await keeperStep(deps, st);
    st = r.state;
    assert.equal(r.decisions[0]!.kind, "waiting");
    assert.match((r.decisions[0] as { reason: string }).reason, /no fresh price/);
    assert.equal(await provider.getTransactionCount(fx.keeper), nonce0, "no transaction while the oracle is stale");
    assert.equal(r.halted, false);

    // ---- 2. the oracle is fresh again: simulate, send, read back
    const head = await provider.getBlock("latest");
    await fork.setFeed(fx.avaxFeed, BigInt(fx.avaxAnswer8), head.timestamp);
    await fork.setFeed(fx.usdcFeed, BigInt(fx.usdcAnswer8), head.timestamp);
    r = await keeperStep(deps, st);
    st = r.state;
    const d = r.decisions.find((x) => x.positionId === String(fx.positionId))!;
    assert.equal(d.kind, "finalised", JSON.stringify(r.decisions));
    assert.equal(r.sent, 1);
    assert.equal(st.finalisations.length, 1);
    assert.equal(st.finalisations[0]!.rungsFinalised, 3);
    assert.equal(st.finalisations[0]!.orderSettled, true);
    assert.equal(st.finalisations[0]!.positionClosed, true);
    assert.equal(st.pending, null);
    assert.equal(await provider.getTransactionCount(fx.keeper), nonce0 + 1, "exactly one transaction");

    // ---- on-chain facts: debt repaid first and in full, position closed, the owner holds the rest, the custodian holds nothing
    const after = await exec.positions(fx.positionId);
    assert.equal(Number(after.status), 5, "position CLOSED");
    assert.ok((await pUsdc.borrowBalanceStored(pos.account)).eq(0), "debt repaid");
    const equityPTokens: BigNumber = await vault.freeBalance(fx.alice, fx.pUsdc);
    const equityUsdc = equityPTokens.mul(await pUsdc.exchangeRateStored()).div(utils.parseEther("1"));
    assert.ok(equityUsdc.gt(90_000_000), `owner equity ${equityUsdc.toString()} USDC raw should exceed the 90 USDC margin (the market went up through the ladder)`);
    const USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E";
    const WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";
    assert.ok((await erc20(USDC).balanceOf(fx.custodian)).eq(0), "custodian holds no USDC");
    assert.ok((await erc20(WAVAX).balanceOf(fx.custodian)).eq(0), "custodian holds no WAVAX");
    process.stdout.write(`finalised: gas ${st.finalisations[0]!.gasUsed}, tx ${st.finalisations[0]!.txHash}, debt before ${debtBefore.toString()} -> 0, owner equity ${equityUsdc.toString()} USDC raw (margin 90,000,000)\n`);
    assert.equal(loadState(stateFile).finalisations.length, 1, "the state file has it");

    // ---- 3. next step: the order is over; nothing more is sent
    r = await keeperStep(deps, st);
    assert.equal(r.sent, 0);
    assert.equal(await provider.getTransactionCount(fx.keeper), nonce0 + 1);
    assert.ok(!fork.stats.last429, "no HTTP 429 from the upstream endpoint during the run");
    assert.ok(alerts.some((a) => a.key.startsWith("range-keeper:finalised")));
  } finally {
    await fork.stop();
  }
});
