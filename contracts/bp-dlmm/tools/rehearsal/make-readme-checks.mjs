// Prints the markdown table of every check / note of rehearsal.mjs (id, kind, text with ${...} elided), parsed from the source, so that README.md cannot drift from the code.
//   node make-readme-checks.mjs > checks.md      (README.md embeds the output between the CHECKS markers; `DRY=1 rehearsal.sh` fails when an id in the code is missing from README.md)
import fs from "node:fs";
const src = fs.readFileSync(new URL("./rehearsal.mjs", import.meta.url), "utf8");
function parseArgs(i) { // i = index just after "(": returns the raw argument strings (top level) and the end index
  const args = []; let depth = 0, cur = "", j = i;
  const readString = (q) => { let s = q; j++; while (j < src.length) { const c = src[j]; s += c; if (c === "\\") { s += src[++j]; j++; continue; } if (q === "`" && c === "$" && src[j + 1] === "{") { s += "{"; j += 2; let d = 1; while (d) { const k = src[j]; if (k === "`" || k === '"' || k === "'") { s += readString(k); continue; } if (k === "{") d++; if (k === "}") d--; s += k; j++; } continue; } if (c === q) { j++; return s; } j++; } return s; };
  while (j < src.length) {
    const c = src[j];
    if (c === '"' || c === "'" || c === "`") { cur += readString(c); continue; }
    if (c === "(" || c === "[" || c === "{") depth++;
    if (c === ")" || c === "]" || c === "}") { if (depth === 0) { args.push(cur.trim()); return { args, end: j }; } depth--; }
    if (c === "," && depth === 0) { args.push(cur.trim()); cur = ""; j++; continue; }
    cur += c; j++;
  }
  return { args, end: j };
}
const lit = (a) => { const m = /^(["'`])([\s\S]*)\1$/.exec(a || ""); return m ? m[2].replace(/\$\{[\s\S]*?\}(?=[^}]|$)/g, "…").replace(/\|/g, "\\|") : null; };
const rows = [];
for (const m of src.matchAll(/\b(check|note)\(/g)) {
  const { args } = parseArgs(m.index + m[0].length);
  const id = lit(args[0]); if (!id || !/^B/.test(id)) continue;
  const text = lit(m[1] === "check" ? args[2] : args[1]) ?? "(computed text)";
  rows.push({ id, kind: m[1] === "check" ? "PASS/FAIL" : "NOTE", text: text.replace(/\s+/g, " ").slice(0, 400) });
}
const seen = new Set(); const order = (a, b) => a.id.localeCompare(b.id, "en", { numeric: true });
const out = ["| id | kind | what it asserts / records |", "|---|---|---|"];
for (const r of rows.sort(order)) { if (seen.has(r.id)) continue; seen.add(r.id); out.push(`| \`${r.id}\` | ${r.kind} | ${r.text} |`); }
// ids built from an array inside a loop (not literal arguments of check()): listed by hand so that the README stays complete
out.push("| `B7.1a`, `B7.1b` | PASS/FAIL | donating 1 USDC and 20 USDC to the vault: the best-placed holder's extra borrow power at CF 50 % is below the cost and below CF x donation |");
out.push("| `B7.4a`, `B7.4b`, `B7.4c` | PASS/FAIL (NOTE when a size cannot be swapped) | swapping 1,000 / 10,000 / 100,000 USDC -> USDT in the vault's pool: extra borrow power of the best-placed holder is not above the swap's cost at the oracle |");
const table = out.join("\n");
if (process.argv.includes("--write")) {
  const f = new URL("./README.md", import.meta.url); const r = fs.readFileSync(f, "utf8");
  const a = r.indexOf("<!-- CHECKS:BEGIN -->"), b = r.indexOf("<!-- CHECKS:END -->");
  if (a < 0 || b < 0) { console.error("markers missing in README.md"); process.exit(2); }
  fs.writeFileSync(f, r.slice(0, a) + "<!-- CHECKS:BEGIN -->\n" + table + "\n" + r.slice(b));
  console.log(`README.md updated: ${seen.size} check ids`);
} else console.log(table);
