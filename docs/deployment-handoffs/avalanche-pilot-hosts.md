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

An existing Droplet `linkoraclemonad` and firewall `peridot-web` of the same account are not part of the pilot and were not touched.
