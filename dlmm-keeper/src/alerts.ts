// De-duplicating AlertManager and sinks (trimmed from the production keeper's alert module). Text ALWAYS passes through mask() before it leaves the process.
// Credentials come from the environment only. No alert is an instruction to act automatically: a message to a human.
import { mask } from "./mask";

export type Severity = "info" | "warn" | "crit";
export interface AlertMessage {
  kind: "new" | "severity-up" | "resolved" | "action";
  key: string;
  severity: Severity;
  text: string;
  audience: "keeper-operator";
  ageSeconds?: number;
}
export interface AlertSink {
  send(msg: AlertMessage): Promise<void>;
}
export interface Finding {
  key: string;
  severity: Severity;
  message: string;
  audience: "keeper-operator";
}
interface Active {
  firstSeen: number;
  severity: Severity;
}
export interface AlertStateJson {
  active: Record<string, Active>;
}
const rank: Record<Severity, number> = { info: 0, warn: 1, crit: 2 };

export class AlertManager {
  private active = new Map<string, Active>();
  constructor(private readonly sink: AlertSink, restore?: AlertStateJson) {
    if (restore) for (const [k, v] of Object.entries(restore.active)) this.active.set(k, v);
  }
  toJson(): AlertStateJson {
    return { active: Object.fromEntries(this.active) };
  }
  isActive(key: string): boolean {
    return this.active.has(key);
  }
  /** one message that is NOT de-duplicated (a transaction that was sent, a halt). Text is masked. A failing sink never breaks a cycle. */
  async notify(msg: AlertMessage): Promise<AlertMessage> {
    const m = { ...msg, text: mask(msg.text) };
    await this.deliver(m);
    return m;
  }
  /** announce that a raised key is resolved (no-op when it is not active) */
  async clear(key: string, nowSeconds: number): Promise<void> {
    const cur = this.active.get(key);
    if (!cur) return;
    this.active.delete(key);
    await this.deliver({ kind: "resolved", key, severity: cur.severity, text: mask(`resolved: ${key}`), audience: "keeper-operator", ageSeconds: nowSeconds - cur.firstSeen });
  }
  /** raise a keyed finding once (again only when its severity goes up) */
  async raise(f: Finding, nowSeconds: number): Promise<AlertMessage[]> {
    const cur = this.active.get(f.key);
    if (cur && rank[cur.severity] >= rank[f.severity]) return [];
    if (!cur) this.active.set(f.key, { firstSeen: nowSeconds, severity: f.severity });
    else cur.severity = f.severity;
    const m: AlertMessage = { kind: cur ? "severity-up" : "new", key: f.key, severity: f.severity, text: mask(f.message), audience: f.audience };
    await this.deliver(m);
    return [m];
  }
  private async deliver(m: AlertMessage): Promise<void> {
    try {
      await this.sink.send(m);
    } catch (e) {
      console.error(mask(`alert delivery failed: ${e instanceof Error ? e.message : String(e)}`));
    }
  }
}

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
    const text = `[${msg.severity.toUpperCase()}] ${msg.kind}\n${msg.text}`;
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
    const token = env.DLMM_KEEPER_ALERT_TELEGRAM_TOKEN;
    const chat = env.DLMM_KEEPER_ALERT_TELEGRAM_CHAT_ID;
    if (!token || !chat) throw new Error("alert channel telegram: DLMM_KEEPER_ALERT_TELEGRAM_TOKEN and DLMM_KEEPER_ALERT_TELEGRAM_CHAT_ID must be set in the environment");
    return new TelegramSink(token, chat);
  }
  const url = env.DLMM_KEEPER_ALERT_WEBHOOK_URL;
  if (!url) throw new Error("alert channel webhook: DLMM_KEEPER_ALERT_WEBHOOK_URL must be set in the environment");
  return new WebhookSink(url);
}
