#!/usr/bin/env bash
# Run FROM the admin machine against one created Droplet: ships the operator sources, builds the image ON the Droplet, and generates the keystore ON the
# Droplet. The password is generated on the Droplet (openssl), written to /etc/pilot/<role>.env (root, mode 600) and never leaves it; only the PUBLIC
# ADDRESS is printed. Usage: bootstrap-droplet.sh <role: op1|op2|keeper|rebalancer> <droplet ip>
set -euo pipefail
ROLE="${1:?role}"; IP="${2:?ip}"
case "$ROLE" in op1|op2) PWENV=OPERATOR_KEYSTORE_PASSWORD;; keeper) PWENV=KEEPER_KEYSTORE_PASSWORD;; rebalancer) PWENV=REBALANCER_KEYSTORE_PASSWORD;; *) echo "bad role" >&2; exit 2;; esac
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -i "${PILOT_SSH_KEY:-$HOME/.ssh/peridot-pilot_ed25519}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$IP")
"${SSH[@]}" 'until [ -f /opt/pilot/cloud-init-done ]; do sleep 3; done; if ! swapon --show | grep -q .; then fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi'
tar --exclude node_modules --exclude dist --exclude .forge-out --exclude .forge-cache --exclude state -czf - -C "$SRC" . | "${SSH[@]}" 'rm -rf /opt/pilot/operator && mkdir -p /opt/pilot/operator && tar xzf - -C /opt/pilot/operator && docker build -q -t pilot-operator:local /opt/pilot/operator >/dev/null && echo image built'
# keystore + password: generated inside a throwaway container, on the Droplet, on the data volume (mounted by DigitalOcean at /mnt/pilot_<role>_data)
"${SSH[@]}" bash -s -- "$ROLE" "$PWENV" <<'REMOTE'
set -euo pipefail
ROLE="$1"; PWENV="$2"
VOL="/mnt/pilot_${ROLE}_data"
if ! mountpoint -q "$VOL"; then
  DEV="/dev/disk/by-id/scsi-0DO_Volume_pilot-${ROLE}-data"
  for i in $(seq 1 30); do [ -e "$DEV" ] && break; sleep 2; done
  [ -e "$DEV" ] || { echo "data volume device not present" >&2; exit 1; }
  mkdir -p "$VOL" && mount -o defaults,nofail,discard,noatime "$DEV" "$VOL"
  grep -q "$VOL" /etc/fstab || echo "$DEV $VOL ext4 defaults,nofail,discard,noatime 0 2" >> /etc/fstab
fi
mkdir -p "$VOL/keystore" "$VOL/state" "$VOL/config" && chown -R 1000:1000 "$VOL/keystore" "$VOL/state" "$VOL/config" && chmod 700 "$VOL/keystore"   # uid 1000 = the image's `node` user
if [ -f "$VOL/keystore/$ROLE.json" ]; then echo "keystore exists, nothing generated"; cat "$VOL/address.txt"; exit 0; fi
umask 077
PW="$(openssl rand -base64 36)"
printf '%s=%s\n' "$PWENV" "$PW" > "/etc/pilot/$ROLE.env"; chmod 600 "/etc/pilot/$ROLE.env"
# the password goes to the container through an env file that is deleted right after; it is not an argument and not in the image
trap 'shred -u /root/.ksenv 2>/dev/null || rm -f /root/.ksenv' EXIT
printf 'KS_PASSWORD=%s\n' "$PW" > /root/.ksenv
docker run --rm --user 1000:1000 --env-file /root/.ksenv -v "$VOL/keystore:/out" --entrypoint node pilot-operator:local -e '
const { Wallet } = require("ethers"); const fs = require("fs");
(async () => { const w = Wallet.createRandom(); fs.writeFileSync("/out/'"$ROLE"'.json", await w.encrypt(process.env.KS_PASSWORD), { mode: 0o600 }); console.log(w.address); })();' > "$VOL/address.txt"
shred -u /root/.ksenv 2>/dev/null || rm -f /root/.ksenv
chmod 600 "$VOL/keystore/$ROLE.json"
echo "ADDRESS $(cat "$VOL/address.txt")"
REMOTE
