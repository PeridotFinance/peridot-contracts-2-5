// Host-side configuration helper (runs inside the image, on the Droplet). PUBLIC values only: no key, no endpoint, no password.
//   node scripts/host-config.js init            writes /data/config/host.json from config/dlmm-keeper.mainnet.json with the wallet address in /data/address.txt, mode dry-run
//   node scripts/host-config.js set-vault 0x..  puts the vault address into /data/config/host.json and forces mode dry-run
const fs = require("fs");
const FILE = "/data/config/host.json";
const [cmd, arg] = process.argv.slice(2);
if (cmd === "init") {
  const c = JSON.parse(fs.readFileSync("/app/config/dlmm-keeper.mainnet.json", "utf8"));
  const a = fs.readFileSync("/data/address.txt", "utf8").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error("/data/address.txt does not hold an address");
  c.keeper.address = a;
  c.mode = "dry-run";
  fs.mkdirSync("/data/config", { recursive: true });
  fs.writeFileSync(FILE, JSON.stringify(c, null, 2) + "\n");
  console.log("host config written (mode dry-run, vault UNSET)");
} else if (cmd === "set-vault") {
  if (!/^0x[0-9a-fA-F]{40}$/.test(arg || "")) throw new Error("set-vault needs a 0x address");
  const c = JSON.parse(fs.readFileSync(FILE, "utf8"));
  c.vault = arg;
  c.mode = "dry-run";
  fs.writeFileSync(FILE, JSON.stringify(c, null, 2) + "\n");
  console.log("vault set in the host config (mode dry-run)");
} else throw new Error("usage: host-config.js init | set-vault <0x address>");
