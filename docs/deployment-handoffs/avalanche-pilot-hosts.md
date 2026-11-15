# Pilot hosts and public addresses (created 9 Nov 2026)

Four DigitalOcean Droplets (fra1, s-1vcpu-1gb, Ubuntu 24.04, Docker, 2 GiB swap, one 1 GiB ext4 volume each at `/mnt/pilot_<role>_data`), tag `pilot`, firewall `pilot-fw` (SSH only from the admin address, everything outbound). SSH key: a dedicated key `peridot-pilot-fleet` (private half on the admin machine only). Created by `operator/deploy/provision-droplets.sh --go`; image built and keystores generated on each Droplet by `operator/deploy/bootstrap-droplet.sh`. **No process is running yet** (no configuration, no funding, no RPC value on the hosts).

| Role | Droplet | IPv4 | Public address (keystore on the Droplet) | Keystore password |
| --- | --- | --- | --- | --- |
| Operator 1 | `pilot-op1` (617379747) | 188.166.161.148 | `0xA7640fc537E2172eD6c4b4A809C9456AbD60fbF4` | `/etc/pilot/op1.env` on the Droplet (root, 600) |
| Operator 2 | `pilot-op2` (617379849) | 164.92.141.163 | `0xfbb137eBcBb0F7eb2Ba70F59ff0be9B0A0c5125d` | `/etc/pilot/op2.env` |
| Treasury keeper | `pilot-keeper` (617379984) | 68.183.219.154 | `0xaF0FAcd12A02b5b030eC7C3bf5dE0726C828935D` | `/etc/pilot/keeper.env` |
| Rebalancer | `pilot-rebalancer` (617380100) | 139.59.209.151 | `0x70f341B85222cF2E590E40d596DdBD7bF0a3ddB9` | `/etc/pilot/rebalancer.env` |
| **Throwaway margin deployer** | on `pilot-keeper` | n/a | `0x7413c1C72BAAfFc640C00Ba759BF14826b12C8C7` | `/root/deployer.password` on `pilot-keeper` (root, 600); keystore `/mnt/pilot_keeper_data/deployer/deployer.json` |

Keystores are encrypted (scrypt) files owned by uid 1000 (the image's `node` user), mode 600, in a mode-700 directory. The deployer is generated the same way; to run margin stage 1 you copy `deployer.json` and read its password (`scp` / `ssh root@68.183.219.154 cat /root/deployer.password`), import it into a Foundry keystore on your machine, and delete both afterwards. The deployer holds nothing after stage 1 (`verify` asserts it).

**Funding and gas floor (CAP = 200, `avalanche-pilot-sizing-table.md`):** each of the four host wallets gets **0.1 AVAX**; the process AVAX alert floor is **0.04 AVAX = `40000000000000000` wei** (`minGasWei`). The throwaway deployer gets 0.12 AVAX.

## Runbook: SSH firewall: my public IP changed
The firewall `pilot-fw` (id `8f21808a-01d3-4b02-a55f-c2b1b2ad8ca4`, applied by tag `pilot`) has exactly one inbound rule: TCP port 22 from the admin address as `/32`; everything outbound is allowed (icmp, tcp, udp). When your public IP changes, SSH to all four Droplets stops until the rule is replaced.

1. Read the current rule (read-only):
```
doctl compute firewall get 8f21808a-01d3-4b02-a55f-c2b1b2ad8ca4 --format Name,InboundRules,OutboundRules,Tags
```
2. Replace the rule with ONE command (run by you with a token that is allowed to update firewalls). `update` replaces the whole firewall in one call, so there is no moment without an SSH rule (the `remove-rules` + `add-rules` pair would be two calls and can lock you out between them). It must repeat the existing outbound rules and the tag, because `update` resets whatever is not given:
```
doctl compute firewall update 8f21808a-01d3-4b02-a55f-c2b1b2ad8ca4 --name pilot-fw --tag-names pilot --inbound-rules "protocol:tcp,ports:22,address:$(curl -4 -s https://api.ipify.org)/32" --outbound-rules "protocol:icmp,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:0,address:0.0.0.0/0,address:::/0 protocol:udp,ports:0,address:0.0.0.0/0,address:::/0"
```
Before running it, compare the outbound rules and the tag printed by step 1 with the ones in the command (they were as above on 9 Nov 2026); if they differ, copy the step-1 values. The new address must be your real public IPv4 (`curl -4 -s https://api.ipify.org` prints it; behind a VPN it is the VPN's). Afterwards run step 1 again: the inbound rule must show `protocol:tcp,ports:22,address:<new IP>/32` only, and `ssh -i ~/.ssh/peridot-pilot_ed25519 root@<droplet ip> true` must work. Nothing is open to `0.0.0.0/0` inbound at any time.

**Checked with `doctl compute firewall update --help`, `add-rules --help` and `remove-rules --help` only; the commands above were NOT run.** Only the read-only `list` and `get` were run, to find the id, the tag and the current rule (step 1 was run in this form).

An existing Droplet `linkoraclemonad` and firewall `peridot-web` of the same account are not part of the pilot and were not touched.
