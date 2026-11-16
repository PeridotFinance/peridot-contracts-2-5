// Alert engine: de-duplication, escalation timers (1 h / 4 h / 24 h) and delivery. Alert TEXT is always passed through mask() before it
// leaves the process. Credentials come from the environment only. No alert is ever an instruction to act automatically: the monitor has no
// signer and sends nothing to the chain; "consider pausing" is a message to a human.
import { mask } from "./mask";
import type { Finding, Severity } from "./health";
import type { MonitorConfig } from "./config";

export interface AlertMessage {
  kind: "new" | "severity-up" | "escalation" | "resolved" | "payment" | "action";
  key: string;
  severity: Severity;
  text: string;
  audience: Finding["audience"];
  /** for escalations: which timer (seconds since first seen) fired */
  escalationSeconds?: number;
  ageSeconds?: number;
}
export interface AlertSink {
  send(msg: AlertMessage): Promise<void>;
}

interface Active {
  firstSeen: number;
  severity: Severity;
  escalationsSent: number;
}
export interface AlertStateJson {
  active: Record<string, Active>;
}

const rank: Record<Severity, number> = { info: 0, warn: 1, crit: 2 };

export class AlertManager {
  private active = new Map<string, Active>();
  /** consecutive failed deliveries; while the sink is "down" no send is attempted until sinkDownUntil (exponential back-off 30 s .. 15 min) */
  private failures = 0;
  private sinkDownUntil = 0;
  private readonly nowMs: () => number;
  constructor(
    private readonly sink: AlertSink,
    private readonly escalationSeconds: number[],
    restore?: AlertStateJson,
    opts: { nowMs?: () => number } = {},
  ) {
    this.nowMs = opts.nowMs ?? (() => Date.now());
    if (restore) for (const [k, v] of Object.entries(restore.active)) this.active.set(k, v);
  }

  toJson(): AlertStateJson {
    return { active: Object.fromEntries(this.active) };
  }

  /**
   * Delivery NEVER throws. A failing sink (Telegram HTTP 429, DNS, timeout, a hung connection) must not break a cycle, and must not skip the code that
   * follows a sent transaction. On failure: the (masked) failure and the alert itself go to the process log (so the journal still has it), and sends are
   * paused with exponential back-off (30 s, 60 s, ... 15 min) instead of hammering a failing endpoint every cycle. Returns whether the sink accepted it.
   */
  private async deliver(m: AlertMessage, oneShot = false): Promise<boolean> {
    if (this.nowMs() < this.sinkDownUntil) {
      // a raise / process finding is retried after the back-off (state rolled back), so it is not repeated in the log; a one-shot notice is dropped, so it is logged here
      if (oneShot) console.log(mask(JSON.stringify({ alert: m, delivery: "dropped: sink in back-off" })));
      return false;
    }
    try {
      await this.sink.send(m);
      this.failures = 0;
      return true;
    } catch (e) {
      this.failures++;
      this.sinkDownUntil = this.nowMs() + Math.min(900_000, 30_000 * 2 ** (this.failures - 1));
      console.error(mask(`alert delivery failed (${this.failures} in a row, next attempt in ${Math.round((this.sinkDownUntil - this.nowMs()) / 1000)} s): ${e instanceof Error ? e.message : String(e)}`));
      console.log(mask(JSON.stringify({ alert: m, delivery: "failed" })));
      return false;
    }
  }

  /** Send a message that is NOT de-duplicated (one per payment). Text is masked. Never throws; a dropped one is in the process log. */
  async notify(msg: AlertMessage): Promise<AlertMessage> {
    const m = { ...msg, text: mask(msg.text) };
    await this.deliver(m, true);
    return m;
  }

  /** Announce that a raised key is resolved (no-op when it is not active). */
  async clear(key: string, nowSeconds: number): Promise<void> {
    const cur = this.active.get(key);
    if (!cur) return;
    this.active.delete(key);
    await this.deliver({ kind: "resolved", key, severity: cur.severity, text: mask(`resolved: ${key}`), audience: "monitor-operator", ageSeconds: nowSeconds - cur.firstSeen }, true);
  }

  /** Raise one finding WITHOUT touching the others (used when a cycle failed and nothing else can be judged). A raise whose delivery failed is retried by the next call. */
  async raise(f: Finding, nowSeconds: number): Promise<AlertMessage[]> {
    const cur = this.active.get(f.key);
    if (cur && rank[cur.severity] >= rank[f.severity]) return [];
    const prev = cur ? cur.severity : undefined;
    if (!cur) this.active.set(f.key, { firstSeen: nowSeconds, severity: f.severity, escalationsSent: 0 });
    else cur.severity = f.severity;
    const m: AlertMessage = { kind: cur ? "severity-up" : "new", key: f.key, severity: f.severity, text: mask(f.message), audience: f.audience };
    if (!(await this.deliver(m))) {
      if (prev === undefined) this.active.delete(f.key);
      else this.active.get(f.key)!.severity = prev;
      return [];
    }
    return [m];
  }

  /** `info` findings are recorded in the report but never sent. A finding whose delivery failed stays "not yet announced" and is retried by the next call. */
  async process(findings: Finding[], nowSeconds: number): Promise<AlertMessage[]> {
    const sent: AlertMessage[] = [];
    const emit = async (m: AlertMessage): Promise<boolean> => {
      const safe = { ...m, text: mask(m.text) };
      const ok = await this.deliver(safe, m.kind === "resolved");
      if (ok) sent.push(safe);
      return ok;
    };
    const seen = new Set<string>();
    for (const f of findings) {
      if (f.severity === "info") continue;
      seen.add(f.key);
      const cur = this.active.get(f.key);
      if (!cur) {
        this.active.set(f.key, { firstSeen: nowSeconds, severity: f.severity, escalationsSent: 0 });
        if (!(await emit({ kind: "new", key: f.key, severity: f.severity, text: f.message, audience: f.audience }))) this.active.delete(f.key);
        continue;
      }
      if (rank[f.severity] > rank[cur.severity]) {
        const prev = cur.severity;
        cur.severity = f.severity;
        if (!(await emit({ kind: "severity-up", key: f.key, severity: f.severity, text: f.message, audience: f.audience }))) cur.severity = prev;
      }
      if (f.escalates) {
        const age = nowSeconds - cur.firstSeen;
        while (cur.escalationsSent < this.escalationSeconds.length && age >= this.escalationSeconds[cur.escalationsSent]!) {
          const t = this.escalationSeconds[cur.escalationsSent]!;
          cur.escalationsSent++;
          if (!(await emit({ kind: "escalation", key: f.key, severity: "crit", text: `STILL UNRESOLVED after ${Math.round(t / 3600)} h: ${f.message}`, audience: f.audience, escalationSeconds: t, ageSeconds: age }))) {
            cur.escalationsSent--;
            break;
          }
        }
      }
    }
    for (const [k, v] of [...this.active]) {
      if (!seen.has(k)) {
        this.active.delete(k);
        await emit({ kind: "resolved", key: k, severity: v.severity, text: `resolved: ${k}`, audience: "monitor-operator", ageSeconds: nowSeconds - v.firstSeen });
      }
    }
    return sent;
  }
}

// ---------------------------------------------------------------- sinks
export class MemorySink implements AlertSink {
  readonly messages: AlertMessage[] = [];
  async send(msg: AlertMessage): Promise<void> {
    this.messages.push(msg);
  }
}
export class StdoutSink implements AlertSink {
  async send(msg: AlertMessage): Promise<void> {
    console.log(JSON.stringify({ alert: msg }));
  }
}
type FetchInit = { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal };
type FetchLike = (url: string, init: FetchInit) => Promise<{ ok: boolean; status: number }>;

/** One HTTP POST with a hard timeout (default 10 s): an AbortController for fetch AND a timer race, so a transport that ignores the signal cannot hang a cycle either. */
export async function postWithTimeout(fetchFn: FetchLike, url: string, init: Omit<FetchInit, "signal">, timeoutMs: number): Promise<{ ok: boolean; status: number }> {
  const ac = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ac.abort();
      reject(new Error(`alert delivery timed out after ${timeoutMs} ms`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([fetchFn(url, { ...init, signal: ac.signal }), deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export class TelegramSink implements AlertSink {
  constructor(private readonly token: string, private readonly chatId: string, private readonly fetchFn: FetchLike = fetch as unknown as FetchLike, private readonly timeoutMs: number = 10_000) {}
  async send(msg: AlertMessage): Promise<void> {
    const text = `[${msg.severity.toUpperCase()}] ${msg.kind} (${msg.audience})\n${msg.text}`;
    const r = await postWithTimeout(this.fetchFn, `https://api.telegram.org/bot${this.token}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id: this.chatId, text }) }, this.timeoutMs);
    if (!r.ok) throw new Error(`telegram delivery failed with HTTP ${r.status}`); // the URL (which contains the token) is never part of the message
  }
}
export class WebhookSink implements AlertSink {
  constructor(private readonly url: string, private readonly fetchFn: FetchLike = fetch as unknown as FetchLike, private readonly timeoutMs: number = 10_000) {}
  async send(msg: AlertMessage): Promise<void> {
    const r = await postWithTimeout(this.fetchFn, this.url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(msg) }, this.timeoutMs);
    if (!r.ok) throw new Error(`webhook delivery failed with HTTP ${r.status}`);
  }
}

/** Builds the sink of the configured channel. Throws (so the process refuses to start) when its credentials are not in the environment. */
export function createSink(cfg: MonitorConfig, env: NodeJS.ProcessEnv = process.env): AlertSink {
  if (cfg.alerts.channel === "log") return new StdoutSink(); // until the Telegram bot exists
  if (cfg.alerts.channel === "telegram") {
    const token = env.OPERATOR_ALERT_TELEGRAM_TOKEN;
    const chat = env.OPERATOR_ALERT_TELEGRAM_CHAT_ID;
    if (!token || !chat) throw new Error("alert channel telegram: OPERATOR_ALERT_TELEGRAM_TOKEN and OPERATOR_ALERT_TELEGRAM_CHAT_ID must be set in the environment");
    return new TelegramSink(token, chat);
  }
  const url = env.OPERATOR_ALERT_WEBHOOK_URL;
  if (!url) throw new Error("alert channel webhook: OPERATOR_ALERT_WEBHOOK_URL must be set in the environment");
  return new WebhookSink(url);
}
