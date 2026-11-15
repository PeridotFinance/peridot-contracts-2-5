// The WHOLE PROCESS (main.ts `run`, live mode) against a local anvil with block-time 1 (chain time = real time): keystore + password file from the environment,
// the real 60 s wait (real seconds), one rebalance mined, state file written, SIGTERM stops after the cycle. Takes about 75 s.
import test from "node:test";
import assert from "node:assert/strict";
import { ChildProcess, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { deployWorld, startAnvil, toolsAvailable, compileStubs } from "./harness";

const skip = !toolsAvailable() ? "anvil/forge not installed" : false;

test("process e2e: `run` in live mode waits the real 60 s, sends exactly one rebalance with the keystore signer, persists state, stops cleanly on SIGTERM; no secret in any output", { skip }, async () => {
  compileStubs();
  const anvil = await startAnvil(1);
  let proc: ChildProcess | undefined;
  try {
    const w = await deployWorld(anvil, (c) => { c.mode = "live"; c.timing.pollSeconds = 1; });
    const ks = path.join(w.dir, "ks.json");
    const pw = path.join(w.dir, "pw");
    const PASSWORD = "process-test-password-xyz-123";
    fs.writeFileSync(ks, await w.keeper.encrypt(PASSWORD, { scrypt: { N: 256 } }), { mode: 0o600 });
    fs.writeFileSync(pw, PASSWORD + "\n", { mode: 0o600 });
    const cfgPath = path.join(w.dir, "c.json");
    fs.writeFileSync(cfgPath, JSON.stringify(w.cfg));
    const t0 = Date.now();
    proc = spawn("node", [path.join(__dirname, "..", "..", "src", "main.js"), "run", "--config", cfgPath], {
      env: { PATH: process.env.PATH, AVALANCHE_MAINNET_RPC_URL: `${anvil.url}/?key=key-like-segment-ABCDEFGH12345`, DLMM_KEEPER_KEYSTORE_PATH: ks, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: pw },
    });
    let out = "";
    let err = "";
    const child = proc;
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (err += d));
    const closed = new Promise<number | null>((r) => child.on("close", r));
    await new Promise((r) => setTimeout(r, 3000));
    await w.exitUp(100_000_000n);
    const exitAt = Date.now();
    let count = 0;
    while (Date.now() - exitAt < 120_000) {
      count = Number(await w.vault.rebalanceCount());
      if (count >= 1) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    const waited = (Date.now() - exitAt) / 1000;
    assert.equal(count, 1, `no rebalance within 120 s\n${out}\n${err}`);
    assert.ok(waited >= 58, `the 60 s wait was honoured (waited ${waited} s)`);
    await new Promise((r) => setTimeout(r, 3000)); // let the cycle persist its read-back
    child.kill("SIGTERM");
    assert.equal(await closed, 0);
    assert.match(out, /stopped after the current cycle/);
    assert.equal(Number(await w.vault.rebalanceCount()), 1, "exactly one");
    assert.equal(await anvil.provider.getTransactionCount(w.keeper.address), 1);
    const st = JSON.parse(fs.readFileSync(w.cfg.monitor.statePath, "utf8"));
    assert.equal(st.sends.length, 1);
    assert.equal(st.sends[0].outcome, "ok");
    assert.equal(st.pending, null);
    assert.ok(!fs.existsSync(w.cfg.monitor.haltPath));
    for (const secret of [PASSWORD, "key-like-segment-ABCDEFGH12345", anvil.url]) assert.ok(!out.includes(secret) && !err.includes(secret), "no secret in the output");
    assert.ok(!fs.readFileSync(w.cfg.monitor.statePath, "utf8").includes(PASSWORD));
    void t0;
  } finally {
    proc?.kill("SIGKILL"); // never leave the keeper process behind, whatever failed
    anvil.stop();
  }
});
