// Keeps a PRIVATE RPC endpoint (and any other env-supplied secret) out of logs, alerts, thrown errors and state files.
// Model: contracts/tools/avalanche-redact-rpc.py. The secret is read from the ENVIRONMENT only; nothing here writes it anywhere.
// ethers v5 puts the request URL into provider error messages and error objects, so EVERY string that leaves the process goes through mask().

const MASK = "[RPC-MASKED]";

function secretsOf(value: string): string[] {
  const out = new Set<string>();
  if (value.length < 6) return []; // unset or a placeholder; nothing worth masking
  out.add(value);
  out.add(value.replace(/\/+$/, ""));
  try {
    const u = new URL(value);
    if (u.host) out.add(u.host);
    if (u.hostname) out.add(u.hostname);
    for (const part of [u.username, u.password]) if (part && part.length >= 4) out.add(decodeURIComponent(part));
    const segs = [...u.pathname.split("/"), ...u.search.replace(/^\?/, "").replace(/[=&]/g, "/").split("/")];
    for (const s of segs) {
      let d = s;
      try {
        d = decodeURIComponent(s);
      } catch {
        /* keep raw */
      }
      if (d.length >= 8) out.add(d); // key-like tokens; short path words ("ext", "bc", "C", "rpc") stay readable
    }
  } catch {
    /* not a URL (a bare token): the whole value is masked above */
  }
  return [...out].filter((s) => s.length > 0).sort((a, b) => b.length - a.length);
}

/** Names of the environment variables whose values are secrets and must never be printed. */
export const SECRET_ENV_NAMES = [
  "AVALANCHE_MAINNET_RPC_URL",
  "AVALANCHE_RPC",
  "OPERATOR_RPC_URL",
  "OPERATOR_ALERT_TELEGRAM_TOKEN",
  "OPERATOR_ALERT_WEBHOOK_URL",
  "KEEPER_KEYSTORE_PASSWORD",
];

let extra: string[] = [];

/** Register further secret strings (for example one read from a file) at run time. */
export function registerSecret(value: string): void {
  extra = [...extra, ...secretsOf(value)];
}

export function currentSecrets(env: NodeJS.ProcessEnv = process.env, names: readonly string[] = SECRET_ENV_NAMES): string[] {
  const all = new Set<string>(extra);
  for (const n of names) for (const s of secretsOf(env[n] ?? "")) all.add(s);
  return [...all].sort((a, b) => b.length - a.length);
}

export function mask(text: string, env: NodeJS.ProcessEnv = process.env): string {
  let out = text;
  for (const s of currentSecrets(env)) if (out.includes(s)) out = out.split(s).join(MASK);
  return out;
}

/** An error message safe to log: masked, one line, bounded. */
export function safeError(e: unknown, env: NodeJS.ProcessEnv = process.env): string {
  const msg = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  return mask(msg, env).replace(/\s+/g, " ").slice(0, 400);
}

export { MASK };
