import test from "node:test";
import assert from "node:assert/strict";
import { mask, safeError } from "../src/mask";

const URL_ = "https://archive-node.example.org/ext/bc/C/rpc/AbCdEf0123456789SecretKey?apikey=ZyXwVu9876543210Token";
const env = { AVALANCHE_MAINNET_RPC_URL: URL_ } as NodeJS.ProcessEnv;

test("the URL, host and key-like tokens are masked wherever they appear", () => {
  const text = `error sending request for url (${URL_}); host archive-node.example.org; token AbCdEf0123456789SecretKey and ZyXwVu9876543210Token`;
  const m = mask(text, env);
  for (const s of ["archive-node.example.org", "AbCdEf0123456789SecretKey", "ZyXwVu9876543210Token", URL_]) assert.ok(!m.includes(s), `leaked ${s}`);
  assert.ok(m.includes("[RPC-MASKED]"));
});
test("short path words stay readable and an unset variable masks nothing", () => {
  assert.equal(mask("ext bc C rpc", env), "ext bc C rpc");
  assert.equal(mask("hello", {} as any), "hello");
});
test("safeError masks, flattens and bounds an ethers-style error", () => {
  const e = new Error(`missing response (requestBody="{...}", requestMethod="POST", serverError={"code":"ECONNRESET"}, url="${URL_}", code=SERVER_ERROR)`);
  const s = safeError(e, env);
  assert.ok(!s.includes("archive-node.example.org") && !s.includes("AbCdEf0123456789SecretKey"));
  assert.ok(s.length <= 400 && !s.includes("\n"));
});
