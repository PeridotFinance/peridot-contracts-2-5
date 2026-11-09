// Alerts: a sink interface plus a console sink. Text is ALWAYS passed through mask() before it leaves the process. No alert is an instruction
// to act automatically: a human clears a halt.
import { mask } from "./mask";

export type Severity = "info" | "warn" | "crit";
export interface Alert {
  key: string;
  severity: Severity;
  text: string;
}
export interface AlertSink {
  send(a: Alert): Promise<void>;
}
export class ConsoleSink implements AlertSink {
  async send(a: Alert): Promise<void> {
    process.stderr.write(`[${a.severity}] ${a.key}: ${a.text}\n`);
  }
}
export class Alerts {
  constructor(private readonly sink: AlertSink) {}
  async raise(key: string, severity: Severity, text: string): Promise<void> {
    await this.sink.send({ key, severity, text: mask(text) });
  }
}
