#!/usr/bin/env bash
# The DLMM keeper's Droplet role "dlmmkeeper" (same pattern as the other keeper roles' host scripts). PREPARED ONLY: nothing in this repository runs it, creates a Droplet,
# or touches an existing one. The deploy is the operator's live step.
#   bootstrap <ip>              ships dlmm-keeper/ sources, builds the image ON the Droplet, mounts the volume, generates the keystore ON the Droplet
#                               (password written to /etc/pilot/dlmmkeeper.password, owner uid 1000, mode 400, never leaves it); prints ONLY the public address.
#   stage <ip> <host.json>      puts the public configuration on the volume, writes AVALANCHE_MAINNET_RPC_URL into /etc/pilot/dlmmkeeper.env from THIS shell's
#                               environment through a pipe (never an argument, never printed), installs the systemd unit WITHOUT enabling or starting it.
#                               Env: AVALANCHE_MAINNET_RPC_URL (required).
# Starting is a separate, explicit step:  ssh root@<ip> systemctl enable --now pilot-dlmm-keeper
# Leaving a HALT:  ssh root@<ip> docker exec dlmm-keeper node dist/src/main.js resume      (offline command: no RPC, no keystore)
# The shipped configuration must say "mode": "dry-run" until the operator has watched a dry-run through at least one exit; "live" is a one-line change in host.json + stage.
set -euo pipefail
CMD="${1:?bootstrap|stage}"; IP="${2:?ip}"
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$HERE/.." && pwd)"
SSH=(ssh -i "${PILOT_SSH_KEY:-$HOME/.ssh/peridot-pilot_ed25519}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$IP")
VOL=/mnt/pilot_dlmmkeeper_data
case "$CMD" in
bootstrap)
  "${SSH[@]}" 'until [ -f /opt/pilot/cloud-init-done ]; do sleep 3; done; if ! swapon --show | grep -q .; then fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi'
  tar --exclude node_modules --exclude dist --exclude state -czf - -C "$SRC" . | "${SSH[@]}" 'rm -rf /opt/pilot/dlmm-keeper && mkdir -p /opt/pilot/dlmm-keeper && tar xzf - -C /opt/pilot/dlmm-keeper && docker build -q -t pilot-dlmm-keeper:local /opt/pilot/dlmm-keeper' | sed 's/^/  build: /'
  "${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
VOL=/mnt/pilot_dlmmkeeper_data
if ! mountpoint -q "$VOL"; then
  DEV=/dev/disk/by-id/scsi-0DO_Volume_pilot-dlmmkeeper-data
  for i in $(seq 1 30); do [ -e "$DEV" ] && break; sleep 2; done
  [ -e "$DEV" ] || { echo "data volume device not present" >&2; exit 1; }
  mkdir -p "$VOL" && mount -o defaults,nofail,discard,noatime "$DEV" "$VOL"
  grep -q "$VOL" /etc/fstab || echo "$DEV $VOL ext4 defaults,nofail,discard,noatime 0 2" >> /etc/fstab
fi
mkdir -p "$VOL/keystore" "$VOL/state" "$VOL/config" /etc/pilot && chown -R 1000:1000 "$VOL/keystore" "$VOL/state" "$VOL/config" && chmod 700 "$VOL/keystore"
if [ -f "$VOL/keystore/dlmm-keeper.json" ]; then echo "keystore exists, nothing generated"; echo "ADDRESS $(cat "$VOL/address.txt")"; exit 0; fi
umask 077
openssl rand -base64 36 > /etc/pilot/dlmmkeeper.password
chown 1000:1000 /etc/pilot/dlmmkeeper.password; chmod 400 /etc/pilot/dlmmkeeper.password
docker run --rm --user 1000:1000 -v /etc/pilot/dlmmkeeper.password:/pw:ro -v "$VOL/keystore:/out" --entrypoint node pilot-dlmm-keeper:local -e '
const { Wallet } = require("ethers"); const fs = require("fs");
(async () => { const pw = fs.readFileSync("/pw", "utf8").replace(/[\r\n]+$/, ""); const w = Wallet.createRandom(); fs.writeFileSync("/out/dlmm-keeper.json", await w.encrypt(pw), { mode: 0o600 }); console.log(w.address); })();' > "$VOL/address.txt"
chmod 600 "$VOL/keystore/dlmm-keeper.json"
echo "ADDRESS $(cat "$VOL/address.txt")"
REMOTE
  ;;
stage)
  CFG="${3:?host.json}"
  : "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
  "${SSH[@]}" "cat > $VOL/config/host.json && chown 1000:1000 $VOL/config/host.json && chmod 644 $VOL/config/host.json" < "$CFG"
  printf 'AVALANCHE_MAINNET_RPC_URL=%s\n' "$AVALANCHE_MAINNET_RPC_URL" | "${SSH[@]}" "set -e; umask 077; touch /etc/pilot/dlmmkeeper.env; sed -i -e '/^AVALANCHE_MAINNET_RPC_URL=/d' /etc/pilot/dlmmkeeper.env; cat >> /etc/pilot/dlmmkeeper.env; chmod 600 /etc/pilot/dlmmkeeper.env; grep -c '^AVALANCHE_MAINNET_RPC_URL=' /etc/pilot/dlmmkeeper.env | sed 's/^/  env lines with the endpoint: /'"
  "${SSH[@]}" "cat > /etc/systemd/system/pilot-dlmm-keeper.service && systemctl daemon-reload && echo \"  unit enabled: \$(systemctl is-enabled pilot-dlmm-keeper 2>&1)  active: \$(systemctl is-active pilot-dlmm-keeper 2>&1)\"" < "$HERE/pilot-dlmm-keeper.service.example" || true
  echo "  staged dlmmkeeper: nothing started"
  ;;
*) echo "bad command" >&2; exit 2 ;;
esac
