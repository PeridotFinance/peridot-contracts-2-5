// Debug helper for `ntt new` => "Already in a git repository"
// Logs to the NDJSON ingest endpoint (no secrets).

import { spawnSync } from "child_process";
import fs from "fs";

const INGEST =
  "http://127.0.0.1:7242/ingest/b2f958aa-2257-4a35-bad0-9c4db4cd8a07";

const sessionId = "debug-session";
const runId = process.env.RUN_ID || "pre-fix";
const target = process.argv[2] || "/home/josh/ntt-debug-project";

function post(
  hypothesisId: string,
  location: string,
  message: string,
  data: any
) {
  // #region agent log
  fetch(INGEST, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      sessionId,
      runId,
      hypothesisId,
      location,
      message,
      data,
      timestamp: Date.now(),
    }),
  }).catch(() => {});
  // #endregion agent log
}

function gitCheck(cwd: string) {
  const res = spawnSync("git", ["rev-parse", "--is-inside-work-tree"], {
    cwd,
    encoding: "utf8",
  });
  return {
    cwd,
    exitCode: res.status ?? -1,
    stdout: (res.stdout || "").trim(),
    stderrFirstLine: (res.stderr || "").trim().split("\n")[0] || "",
    dotGitExists: fs.existsSync(`${cwd}/.git`),
  };
}

function runNttNew(cwd: string, outDir: string) {
  const res = spawnSync("ntt", ["new", outDir], { cwd, encoding: "utf8" });
  const stdout = (res.stdout || "").trim();
  const stderr = (res.stderr || "").trim();
  const firstLine = (stdout || stderr).split("\n")[0] || "";
  return {
    cwd,
    outDir,
    exitCode: res.status ?? -1,
    firstLine,
  };
}

post("H1", "script/ntt_new_debug.ts:begin", "Start debug", {
  target,
  processCwd: process.cwd(),
  nttBin: process.env.PATH ? "set" : "unset",
  gitEnv: {
    GIT_DIR: process.env.GIT_DIR ? "set" : "unset",
    GIT_WORK_TREE: process.env.GIT_WORK_TREE ? "set" : "unset",
  },
});

const dirs = [
  process.cwd(),
  "/home/josh",
  "/home",
  "/tmp",
  "/home/josh/peridot-ccip",
];
const checks = dirs.map(gitCheck);
post("H2", "script/ntt_new_debug.ts:gitCheck", "git rev-parse results", {
  checks,
});

// Try running `ntt new` from the same candidate directories to see which triggers the guard.
const attempts = dirs.map((d) => runNttNew(d, target));
post("H3", "script/ntt_new_debug.ts:nttNew", "ntt new attempts", { attempts });

// Compute a simple classification.
const summary = {
  likelyCause: attempts.find((a) =>
    a.firstLine.includes("Already in a git repository")
  )
    ? "nttNewGuardTriggered"
    : "other",
  guardDirs: attempts
    .filter((a) => a.firstLine.includes("Already in a git repository"))
    .map((a) => a.cwd),
};
post("H4", "script/ntt_new_debug.ts:summary", "Summary", summary);

console.log(
  "ntt new debug finished. See /home/josh/peridot-ccip/.cursor/debug.log"
);
