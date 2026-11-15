import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { providers, Wallet } from "ethers";
import { KeystoreSigner, SignerError } from "../src/signer";
import { mask } from "../src/mask";

const prov = new providers.StaticJsonRpcProvider("http://127.0.0.1:9", { chainId: 43114, name: "x" }); // never contacted
async function setup(): Promise<{ dir: string; ks: string; pw: string; w: Wallet; env: NodeJS.ProcessEnv }> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dk-signer-"));
  const w = Wallet.createRandom();
  const ks = path.join(dir, "keystore.json");
  const pw = path.join(dir, "password");
  fs.writeFileSync(ks, await w.encrypt("pw-test-123-unique-string", { scrypt: { N: 256 } }), { mode: 0o600 });
  fs.writeFileSync(pw, "pw-test-123-unique-string\n", { mode: 0o600 });
  return { dir, ks, pw, w, env: { DLMM_KEEPER_KEYSTORE_PATH: ks, DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: pw } };
}

test("the keystore PATH and the PASSWORD FILE come from the environment; the signer is the keystore's wallet", async () => {
  const s = await setup();
  const signer = await KeystoreSigner.load(prov, s.env);
  assert.equal((await signer.getAddress()).toLowerCase(), s.w.address.toLowerCase());
});
test("a missing variable is named in the error (never a value)", async () => {
  const s = await setup();
  await assert.rejects(KeystoreSigner.load(prov, { DLMM_KEEPER_KEYSTORE_PASSWORD_FILE: s.pw }), /DLMM_KEEPER_KEYSTORE_PATH/);
  await assert.rejects(KeystoreSigner.load(prov, { DLMM_KEEPER_KEYSTORE_PATH: s.ks }), /DLMM_KEEPER_KEYSTORE_PASSWORD_FILE/);
});
test("a wrong password is refused and the error carries neither the password nor the file content", async () => {
  const s = await setup();
  fs.writeFileSync(s.pw, "totally-wrong-password-xyz", { mode: 0o600 });
  await assert.rejects(KeystoreSigner.load(prov, s.env), (e: unknown) => e instanceof SignerError && !/totally-wrong/.test(String(e)) && !/crypto|ciphertext/.test(String(e)));
});
test("a group/other-readable keystore or password file is refused; an empty password file is refused", async () => {
  const s = await setup();
  fs.chmodSync(s.pw, 0o644);
  await assert.rejects(KeystoreSigner.load(prov, s.env), /password file is accessible/);
  fs.chmodSync(s.pw, 0o600);
  fs.chmodSync(s.ks, 0o640);
  await assert.rejects(KeystoreSigner.load(prov, s.env), /keystore file is accessible/);
  fs.chmodSync(s.ks, 0o600);
  fs.writeFileSync(s.pw, "\n");
  fs.chmodSync(s.pw, 0o600);
  await assert.rejects(KeystoreSigner.load(prov, s.env), /empty/);
});
test("missing files and directories are refused", async () => {
  const s = await setup();
  await assert.rejects(KeystoreSigner.load(prov, { ...s.env, DLMM_KEEPER_KEYSTORE_PATH: path.join(s.dir, "nope.json") }), /not found/);
  await assert.rejects(KeystoreSigner.load(prov, { ...s.env, DLMM_KEEPER_KEYSTORE_PATH: s.dir }), /not a file/);
});
test("after loading, the password (from its file) is registered with mask() and cannot reach a log", async () => {
  const s = await setup();
  await KeystoreSigner.load(prov, s.env);
  assert.ok(!mask("the password is pw-test-123-unique-string, honest").includes("pw-test-123-unique-string"));
});
