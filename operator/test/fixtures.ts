// A fully DECIDED configuration built from the checked-in template, with SYNTHETIC values for every undecided field. Test use only.
import fs from "node:fs";
import path from "node:path";

export const TEMPLATE_PATH = path.join(__dirname, "..", "..", "config", "pilot.example.json");
export const A = (n: number): string => "0x" + n.toString(16).padStart(40, "0");

export function template(): any {
  return JSON.parse(fs.readFileSync(TEMPLATE_PATH, "utf8"));
}

export function decidedConfig(over: { treasury?: string; keystorePath?: string; operators?: [string, string] } = {}): any {
  const c = template();
  c.deployment = { controller: A(1), pWavax: A(0x11), pUsdc: A(0x12), oracle: A(0x13), deploymentBlock: 99_000_000 };
  c.operators = [{ name: "op-a", address: over.operators?.[0] ?? A(0x101) }, { name: "op-b", address: over.operators?.[1] ?? A(0x102) }];
  c.reference.minPoolLiquidity = "500";
  c.reference.minPoolLiquiditySource = { fromBlock: 98_000_000, toBlock: 98_302_400, samples: 168, medianLiquidity: "1000", method: "synthetic test value" };
  c.treasury.address = over.treasury ?? A(0x200);
  c.keeper.keystorePath = over.keystorePath ?? "/tmp/synthetic-keystore.json";
  c.keeper.dailySpendCapUsdc = 1500;
  c.executor.operator = "op-a";
  c.executor.keystorePath = "/tmp/synthetic-operator-keystore.json";
  return c;
}
