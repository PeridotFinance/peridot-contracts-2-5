// Copied (trimmed) from operator/src/alerts.ts: de-duplicating AlertManager + sinks. Text always passes through mask().
// Alert engine: de-duplication, escalation timers (1 h / 4 h / 24 h) and delivery. Alert TEXT is always passed through mask() before it
// leaves the process. Credentials come from the environment only. No alert is ever an instruction to act automatically: the monitor has no
// signer and sends nothing to the chain; "consider pausing" is a message to a human.
import { mask } from "./mask";


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

export type Severity = "info" | "warn" | "crit";
export interface Finding {
  key: string;
  severity: Severity;
  message: string;
  audience: "order-keeper" | "keeper-operator" | "guardian";
  escalates?: boolean;
}

const rank: Record<Severity, number> = { info: 0, warn: 1, crit: 2 };

export class AlertManager {
  private active = new Map<string, Active>();
  constructor(
    private readonly sink: AlertSink,
    private readonly escalationSeconds: number[],
    restore?: AlertStateJson,
  ) {
    if (restore) for (const [k, v] of Object.entries(restore.active)) this.active.set(k, v);
  }

  toJson(): AlertStateJson {
    return { active: Object.fromEntries(this.active) };
  }

  /** Send a message that is NOT de-duplicated (one per payment). Text is masked. */
  async notify(msg: AlertMessage): Promise<AlertMessage> {
    const m = { ...msg, text: mask(msg.text) };
    await this.sink.send(m);
    return m;
  }

  /** Announce that a raised key is resolved (no-op when it is not active). */
  async clear(key: string, nowSeconds: number): Promise<void> {
    const cur = this.active.get(key);
    if (!cur) return;
    this.active.delete(key);
    await this.sink.send({ kind: "resolved", key, severity: cur.severity, text: mask(`resolved: ${key}`), audience: "order-keeper", ageSeconds: nowSeconds - cur.firstSeen });
  }

  /** Raise one finding WITHOUT touching the others (used when a cycle failed and nothing else can be judged). */
  async raise(f: Finding, nowSeconds: number): Promise<AlertMessage[]> {
    const cur = this.active.get(f.key);
    if (cur && rank[cur.severity] >= rank[f.severity]) return [];
    if (!cur) this.active.set(f.key, { firstSeen: nowSeconds, severity: f.severity, escalationsSent: 0 });
    else cur.severity = f.severity;
    const m: AlertMessage = { kind: cur ? "severity-up" : "new", key: f.key, severity: f.severity, text: mask(f.message), audience: f.audience };
    await this.sink.send(m);
    return [m];
  }

  /** `info` findings are recorded in the report but never sent. */
  async process(findings: Finding[], nowSeconds: number): Promise<AlertMessage[]> {
    const sent: AlertMessage[] = [];
    const emit = async (m: AlertMessage) => {
      const safe = { ...m, text: mask(m.text) };
      sent.push(safe);
      await this.sink.send(safe);
    };
    const seen = new Set<string>();
    for (const f of findings) {
      if (f.severity === "info") continue;
      seen.add(f.key);
      const cur = this.active.get(f.key);
      if (!cur) {
        this.active.set(f.key, { firstSeen: nowSeconds, severity: f.severity, escalationsSent: 0 });
        await emit({ kind: "new", key: f.key, severity: f.severity, text: f.message, audience: f.audience });
        continue;
      }
      if (rank[f.severity] > rank[cur.severity]) {
        cur.severity = f.severity;
        await emit({ kind: "severity-up", key: f.key, severity: f.severity, text: f.message, audience: f.audience });
      }
      if (f.escalates) {
        const age = nowSeconds - cur.firstSeen;
        while (cur.escalationsSent < this.escalationSeconds.length && age >= this.escalationSeconds[cur.escalationsSent]!) {
          const t = this.escalationSeconds[cur.escalationsSent]!;
          cur.escalationsSent++;
          await emit({ kind: "escalation", key: f.key, severity: "crit", text: `STILL UNRESOLVED after ${Math.round(t / 3600)} h: ${f.message}`, audience: f.audience, escalationSeconds: t, ageSeconds: age });
        }
      }
    }
    for (const [k, v] of [...this.active]) {
      if (!seen.has(k)) {
        this.active.delete(k);
        await emit({ kind: "resolved", key: k, severity: v.severity, text: `resolved: ${k}`, audience: "order-keeper", ageSeconds: nowSeconds - v.firstSeen });
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
type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ ok: boolean; status: number }>;

export class TelegramSink implements AlertSink {
  constructor(private readonly token: string, private readonly chatId: string, private readonly fetchFn: FetchLike = fetch as unknown as FetchLike) {}
  async send(msg: AlertMessage): Promise<void> {
    const text = `[${msg.severity.toUpperCase()}] ${msg.kind} (${msg.audience})\n${msg.text}`;
    const r = await this.fetchFn(`https://api.telegram.org/bot${this.token}/sendMessage`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id: this.chatId, text }) });
    if (!r.ok) throw new Error(`telegram delivery failed with HTTP ${r.status}`); // the URL (which contains the token) is never part of the message
  }
}
export class WebhookSink implements AlertSink {
  constructor(private readonly url: string, private readonly fetchFn: FetchLike = fetch as unknown as FetchLike) {}
  async send(msg: AlertMessage): Promise<void> {
    const r = await this.fetchFn(this.url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(msg) });
    if (!r.ok) throw new Error(`webhook delivery failed with HTTP ${r.status}`);
  }
}

/** Builds the sink of the configured channel. Throws (so the process refuses to start) when its credentials are not in the environment. */
export function createSink(channel: "log" | "telegram" | "webhook", env: NodeJS.ProcessEnv = process.env): AlertSink {
  if (channel === "log") return new StdoutSink();
  if (channel === "telegram") {
    const token = env.ORDER_KEEPER_ALERT_TELEGRAM_TOKEN;
    const chat = env.ORDER_KEEPER_ALERT_TELEGRAM_CHAT_ID;
    if (!token || !chat) throw new Error("alert channel telegram: ORDER_KEEPER_ALERT_TELEGRAM_TOKEN and ORDER_KEEPER_ALERT_TELEGRAM_CHAT_ID must be set in the environment");
    return new TelegramSink(token, chat);
  }
  const url = env.ORDER_KEEPER_ALERT_WEBHOOK_URL;
  if (!url) throw new Error("alert channel webhook: ORDER_KEEPER_ALERT_WEBHOOK_URL must be set in the environment");
  return new WebhookSink(url);
}
