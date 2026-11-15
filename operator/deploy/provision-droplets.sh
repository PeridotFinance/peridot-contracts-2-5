#!/usr/bin/env bash
# Creates the four pilot Droplets (op1, op2, keeper, rebalancer) with one small volume each and a firewall that admits SSH from ONE address.
# DRY RUN by default: prints what it would do and creates nothing. `--go` creates (this costs money: 4 x s-1vcpu-1gb plus 4 x 1 GiB volumes).
# Needs: doctl authenticated (DIGITALOCEAN_ACCESS_TOKEN in the environment or `doctl auth init`), at least one SSH key in the account.
# No secret is read, printed or written here.
set -euo pipefail
GO=0; [ "${1:-}" = "--go" ] && GO=1
REGION="${DO_REGION:-fra1}"; SIZE="${DO_SIZE:-s-1vcpu-1gb}"; IMAGE="${DO_IMAGE:-ubuntu-24-04-x64}"
ADMIN_IP="${ADMIN_IP:-$(curl -fsS https://api.ipify.org)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROLES=(op1 op2 keeper rebalancer)
run() { echo "+ $*"; if [ "$GO" = 1 ]; then "$@"; fi; }
echo "region=$REGION size=$SIZE image=$IMAGE ssh admitted from=$ADMIN_IP go=$GO"
if [ "$GO" = 1 ]; then
  doctl compute droplet list --no-header --format ID >/dev/null || { echo "doctl is not authorised (token scopes: droplet, volume, firewall, ssh_key, tag)" >&2; exit 1; }
  # a DEDICATED key for the pilot hosts (DO_SSH_KEY_IDS, comma separated ids); never "all keys of the account"
  KEYS="${DO_SSH_KEY_IDS:?set DO_SSH_KEY_IDS to the id(s) of the dedicated pilot SSH key}"
else
  KEYS="${DO_SSH_KEY_IDS:-<dedicated pilot ssh key id>}"
fi
for r in "${ROLES[@]}"; do
  run doctl compute volume create "pilot-$r-data" --region "$REGION" --size 1GiB --fs-type ext4
  run doctl compute droplet create "pilot-$r" --region "$REGION" --size "$SIZE" --image "$IMAGE" --ssh-keys "$KEYS" \
    --user-data-file "$HERE/cloud-init.yaml" --tag-name pilot --wait
  if [ "$GO" = 1 ]; then
    VID="$(doctl compute volume list --no-header --format ID,Name | awk -v n="pilot-$r-data" '$2==n{print $1}')"
    DID="$(doctl compute droplet list --no-header --format ID,Name | awk -v n="pilot-$r" '$2==n{print $1}')"
    [ -n "$VID" ] && [ -n "$DID" ] || { echo "cannot find the volume or Droplet of $r" >&2; exit 1; }
    run doctl compute volume-action attach "$VID" "$DID" --wait   # attached after creation, mounted by bootstrap-droplet.sh
  fi
done
run doctl compute firewall create --name pilot-fw --tag-names pilot \
  --inbound-rules "protocol:tcp,ports:22,address:${ADMIN_IP}/32" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0"
if [ "$GO" = 1 ]; then doctl compute droplet list --tag-name pilot --format Name,PublicIPv4,Status; fi
