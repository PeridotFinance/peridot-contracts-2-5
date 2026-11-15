#!/usr/bin/env bash
# STAGES one host and starts NOTHING: rebuilds the image on the Droplet (bootstrap-droplet.sh; keeps the existing keystore), puts the public configuration
# on the volume, writes the state-endpoint variable into /etc/pilot/<role>.env (root, mode 600) from THIS shell's environment through a pipe (never an
# argument, never printed), and installs the systemd unit WITHOUT enabling or starting it. Usage: stage-host.sh <op1|op2|keeper|rebalancer> <ip>
# Starting is a separate, explicit step:  ssh root@<ip> systemctl enable --now pilot     (that is what lets the process sign).
set -euo pipefail
ROLE="${1:?role}"; IP="${2:?ip}"
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$(cd "$HERE/.." && pwd)"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
case "$ROLE" in op1|op2|keeper) ARG=run;; rebalancer) ARG=rebalance;; *) echo "bad role" >&2; exit 2;; esac
SSH=(ssh -i "${PILOT_SSH_KEY:-$HOME/.ssh/peridot-pilot_ed25519}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$IP")
if [ -z "${SKIP_BUILD:-}" ]; then "$HERE/bootstrap-droplet.sh" "$ROLE" "$IP" | sed 's/^/  bootstrap: /'; fi
# configuration (public values only)
"${SSH[@]}" "cat > /mnt/pilot_${ROLE}_data/config/host.json && chown 1000:1000 /mnt/pilot_${ROLE}_data/config/host.json && chmod 644 /mnt/pilot_${ROLE}_data/config/host.json" < "$SRC/config/hosts/$ROLE.json"
# state endpoint: a pipe from this shell's environment; the remote command line contains no value
# AVALANCHE_LOGS_RPC_URL: the LOG endpoint. Default here = the same free-tier app (10-block getLogs); the Avalanche public RPC is only used when LOGS_URL_MODE=public (it answered 429 from cloud IPs on 9 Nov 2026)
LOGS_LINE="AVALANCHE_LOGS_RPC_URL=$AVALANCHE_MAINNET_RPC_URL"; [ "${LOGS_URL_MODE:-state}" = public ] && LOGS_LINE="AVALANCHE_LOGS_RPC_URL=https://api.avax.network/ext/bc/C/rpc"
printf 'AVALANCHE_MAINNET_RPC_URL=%s\n%s\n' "$AVALANCHE_MAINNET_RPC_URL" "$LOGS_LINE" | "${SSH[@]}" "set -e; umask 077; sed -i -e '/^AVALANCHE_MAINNET_RPC_URL=/d' -e '/^AVALANCHE_LOGS_RPC_URL=/d' /etc/pilot/${ROLE}.env; cat >> /etc/pilot/${ROLE}.env; chmod 600 /etc/pilot/${ROLE}.env; grep -c '^AVALANCHE_.*_RPC_URL=' /etc/pilot/${ROLE}.env | sed 's/^/  env lines with endpoints: /'"
# unit: installed, NOT enabled, NOT started
"${SSH[@]}" "cat > /etc/systemd/system/pilot.service && systemctl daemon-reload && systemctl is-enabled pilot 2>&1 | sed 's/^/  pilot.service enabled: /'; systemctl is-active pilot 2>&1 | sed 's/^/  pilot.service active: /'" <<UNIT || true
[Unit]
Description=pilot ${ROLE} process
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f pilot
ExecStart=/usr/bin/docker run --name pilot --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --env-file /etc/pilot/${ROLE}.env -e KEYSTORE_PATH=/data/keystore/${ROLE}.json -e OPERATOR_CONFIG=/data/config/host.json -v /mnt/pilot_${ROLE}_data:/data pilot-operator:local ${ARG}
ExecStop=/usr/bin/docker stop pilot

[Install]
WantedBy=multi-user.target
UNIT
echo "  staged ${ROLE}: nothing started"
