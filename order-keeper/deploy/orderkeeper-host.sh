#!/usr/bin/env bash
# The order keeper's Droplet role "orderkeeper" (same pattern as operator/deploy/bootstrap-droplet.sh + stage-host.sh for the pilot roles).
#   bootstrap <ip>              ships order-keeper/ sources, builds the image ON the Droplet, mounts the volume, generates the keystore ON the Droplet
#                               (password written to /etc/pilot/orderkeeper.env, root 600, never leaves it); prints ONLY the public address.
#   stage <ip> <host.json>      puts the public configuration on the volume, writes AVALANCHE_MAINNET_RPC_URL / AVALANCHE_LOGS_RPC_URL into
#                               /etc/pilot/orderkeeper.env from THIS shell's environment through a pipe (never an argument, never printed), installs the
#                               systemd unit WITHOUT enabling or starting it. Env: AVALANCHE_MAINNET_RPC_URL (required); AVALANCHE_LOGS_RPC_URL (default = the same).
# Starting is a separate, explicit step:  ssh root@<ip> systemctl enable --now pilot-order-keeper
set -euo pipefail
CMD="${1:?bootstrap|stage}"; IP="${2:?ip}"
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$HERE/.." && pwd)"
SSH=(ssh -i "${PILOT_SSH_KEY:-$HOME/.ssh/peridot-pilot_ed25519}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$IP")
VOL=/mnt/pilot_orderkeeper_data
case "$CMD" in
bootstrap)
  "${SSH[@]}" 'until [ -f /opt/pilot/cloud-init-done ]; do sleep 3; done; if ! swapon --show | grep -q .; then fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi'
  tar --exclude node_modules --exclude dist --exclude state -czf - -C "$SRC" . | "${SSH[@]}" 'rm -rf /opt/pilot/order-keeper && mkdir -p /opt/pilot/order-keeper && tar xzf - -C /opt/pilot/order-keeper && docker build -q -t pilot-order-keeper:local /opt/pilot/order-keeper' | sed 's/^/  build: /'
  "${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
VOL=/mnt/pilot_orderkeeper_data
if ! mountpoint -q "$VOL"; then
  DEV=/dev/disk/by-id/scsi-0DO_Volume_pilot-orderkeeper-data
  for i in $(seq 1 30); do [ -e "$DEV" ] && break; sleep 2; done
  [ -e "$DEV" ] || { echo "data volume device not present" >&2; exit 1; }
  mkdir -p "$VOL" && mount -o defaults,nofail,discard,noatime "$DEV" "$VOL"
  grep -q "$VOL" /etc/fstab || echo "$DEV $VOL ext4 defaults,nofail,discard,noatime 0 2" >> /etc/fstab
fi
mkdir -p "$VOL/keystore" "$VOL/state" "$VOL/config" /etc/pilot && chown -R 1000:1000 "$VOL/keystore" "$VOL/state" "$VOL/config" && chmod 700 "$VOL/keystore"
if [ -f "$VOL/keystore/order-keeper.json" ]; then echo "keystore exists, nothing generated"; echo "ADDRESS $(cat "$VOL/address.txt")"; exit 0; fi
umask 077
PW="$(openssl rand -base64 36)"
printf 'ORDER_KEEPER_KEYSTORE_PASSWORD=%s\n' "$PW" > /etc/pilot/orderkeeper.env; chmod 600 /etc/pilot/orderkeeper.env
trap 'shred -u /root/.ksenv 2>/dev/null || rm -f /root/.ksenv' EXIT
printf 'KS_PASSWORD=%s\n' "$PW" > /root/.ksenv
docker run --rm --user 1000:1000 --env-file /root/.ksenv -v "$VOL/keystore:/out" --entrypoint node pilot-order-keeper:local -e '
const { Wallet } = require("ethers"); const fs = require("fs");
(async () => { const w = Wallet.createRandom(); fs.writeFileSync("/out/order-keeper.json", await w.encrypt(process.env.KS_PASSWORD), { mode: 0o600 }); console.log(w.address); })();' > "$VOL/address.txt"
shred -u /root/.ksenv 2>/dev/null || rm -f /root/.ksenv
chmod 600 "$VOL/keystore/order-keeper.json"
echo "ADDRESS $(cat "$VOL/address.txt")"
REMOTE
  ;;
stage)
  CFG="${3:?host.json}"
  : "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
  LOGS="${AVALANCHE_LOGS_RPC_URL:-$AVALANCHE_MAINNET_RPC_URL}"
  "${SSH[@]}" "cat > $VOL/config/host.json && chown 1000:1000 $VOL/config/host.json && chmod 644 $VOL/config/host.json" < "$CFG"
  printf 'AVALANCHE_MAINNET_RPC_URL=%s\nAVALANCHE_LOGS_RPC_URL=%s\n' "$AVALANCHE_MAINNET_RPC_URL" "$LOGS" | "${SSH[@]}" "set -e; umask 077; sed -i -e '/^AVALANCHE_MAINNET_RPC_URL=/d' -e '/^AVALANCHE_LOGS_RPC_URL=/d' /etc/pilot/orderkeeper.env; cat >> /etc/pilot/orderkeeper.env; chmod 600 /etc/pilot/orderkeeper.env; grep -c '^AVALANCHE_.*_RPC_URL=' /etc/pilot/orderkeeper.env | sed 's/^/  env lines with endpoints: /'"
  "${SSH[@]}" "cat > /etc/systemd/system/pilot-order-keeper.service && systemctl daemon-reload && echo \"  unit enabled: \$(systemctl is-enabled pilot-order-keeper 2>&1)  active: \$(systemctl is-active pilot-order-keeper 2>&1)\"" <<'UNIT' || true
[Unit]
Description=pilot order keeper
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f order-keeper
ExecStart=/usr/bin/docker run --name order-keeper --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --env-file /etc/pilot/orderkeeper.env -e KEYSTORE_PATH=/data/keystore/order-keeper.json -e ORDER_KEEPER_CONFIG=/data/config/host.json -v /mnt/pilot_orderkeeper_data:/data pilot-order-keeper:local run
ExecStop=/usr/bin/docker stop -t 60 order-keeper

[Install]
WantedBy=multi-user.target
UNIT
  echo "  staged orderkeeper: nothing started"
  ;;
*) echo "bad command" >&2; exit 2 ;;
esac
