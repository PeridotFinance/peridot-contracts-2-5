// SELF-TEST helper of the run-2 hardening (started by selftest.sh against a black-hole server that accepts connections and never answers): per-RPC timeout, heartbeat, group watchdog, child
// processes with stdin closed and their own timeout, the log file written by the process itself. MODE = rpc | watchdog | proc.
import { check, group, rpc, runProc, track, finish, results } from "../lib.mjs";
const mode = process.env.HANG_MODE;
if (mode === "rpc") {
  const t0 = Date.now(); let msg = "";
  try { await rpc("eth_blockNumber"); } catch (e) { msg = e.message; }
  console.log(`RPC_RESULT ${/timeout after .*rpc eth_blockNumber/.test(msg) ? "TIMED_OUT_WITH_NAME" : "WRONG: " + msg} in ${Date.now() - t0} ms`);
  const t1 = Date.now(); let m2 = ""; try { await track("a promise that never resolves", new Promise(() => {}), 500); } catch (e) { m2 = e.code; } console.log(`TRACK_RESULT ${m2} in ${Date.now() - t1} ms`);
  process.exit(0);
} else if (mode === "watchdog") {
  await group("H0 a group that hangs on an RPC", async () => { await rpc("eth_chainId"); }, { timeoutMs: 1500 });   // the call has no timeout of its own here (REH_RPC_TIMEOUT_MS is large): the WATCHDOG must end it
  console.log("WATCHDOG_NOT_FIRED");
  finish();
} else if (mode === "proc") {
  const a = await runProc("cat", [], { timeoutMs: 5000, label: "cat (waits on stdin)" });             // stdin is /dev/null: EOF at once
  const b = await runProc("sleep", ["30"], { timeoutMs: 1200, label: "sleep 30" });                    // killed by its own timeout
  const c = await runProc("bash", ["-c", "echo http://secret.example/key; (sleep 20 &) ; exit 3"], { timeoutMs: 8000, label: "grandchild holds the pipe" });
  console.log(`PROC_RESULT cat=${a.code} sleep=${b.code} grandchild=${c.code} redacted=${!/secret/.test(c.out)} ${c.out.includes("<url-redacted>")}`);
  process.exit(0);
}
