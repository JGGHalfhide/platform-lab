#!/usr/bin/env bash
# Local S3 store for Velero: single-node Garage on the build host.
#
#   scripts/backup-store.sh        (or: make backup-store)
#
# Idempotent. Needs sudo on the build host (package, /etc/garage.toml,
# systemd). Secrets come from Ansible Vault:
#   vault_garage_rpc_secret, vault_garage_admin_token,
#   vault_garage_metrics_token          Garage itself
#   vault_velero_s3_key_id, vault_velero_s3_secret
#                                       Velero's key (read/write on the bucket)
#
# - Garage from the Arch package (extra/garage), systemd unit garage.service.
# - S3 API on the libvirt bridge only (S3_BIND, default 192.168.122.1:3900):
#   reachable from the VMs, not from the LAN. Plain HTTP on that host-only
#   bridge; Velero's file-system backups are encrypted by its Kopia
#   repository (docs/recovery.md).
# - Data in /var/lib/garage on the host disk, so backups outlive the cluster.
# - One bucket (BUCKET, default velero) and one key allowed on it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

S3_BIND="${S3_BIND:-192.168.122.1:3900}"
BUCKET="${BUCKET:-velero}"
CAPACITY="${CAPACITY:-100G}"
CONF=/etc/garage.toml
HERE="$REPO_ROOT/scripts/garage"

g() { sudo -u garage garage -c "$CONF" "$@"; }

echo "==> Package"
pacman -Q garage >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm garage

echo "==> $CONF"
tmp="$(mktemp)"
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT
rpc_secret="$(vault_get vault_garage_rpc_secret)" \
admin_token="$(vault_get vault_garage_admin_token)" \
metrics_token="$(vault_get vault_garage_metrics_token)" \
s3_bind="$S3_BIND" \
  python -c 'import os, string, sys; sys.stdout.write(string.Template(open(sys.argv[1]).read()).substitute(os.environ))' \
  "$HERE/garage.toml.tmpl" >"$tmp"
restart=0
if ! sudo cmp -s "$tmp" "$CONF"; then
  sudo install -m 0640 -o garage -g garage "$tmp" "$CONF"
  echo "    updated"
  restart=1
fi

echo "==> systemd"
dropin=/etc/systemd/system/garage.service.d/10-platform-lab.conf
if ! sudo cmp -s "$HERE/10-platform-lab.conf" "$dropin"; then
  sudo install -D -m 0644 "$HERE/10-platform-lab.conf" "$dropin"
  sudo systemctl daemon-reload
  restart=1
fi
sudo systemctl enable --quiet garage.service
if [[ $restart == 1 ]] || ! systemctl is-active --quiet garage.service; then
  sudo systemctl restart garage.service
fi
for _ in $(seq 1 30); do g status >/dev/null 2>&1 && break; sleep 1; done
g status >/dev/null

echo "==> Layout"
node="$(g node id -q | cut -d@ -f1)"
if g layout show 2>/dev/null | grep -q "${node:0:16}"; then
  echo "    node ${node:0:16} has a role"
else
  g layout assign -z lab -c "$CAPACITY" "$node"
  version="$(g layout show | awk '/apply --version/ {print $NF}' | tail -1)"
  g layout apply --version "$version"
fi

echo "==> Bucket $BUCKET and key"
g bucket info "$BUCKET" >/dev/null 2>&1 || g bucket create "$BUCKET"
key_id="$(vault_get vault_velero_s3_key_id)"
if ! g key info "$key_id" >/dev/null 2>&1; then
  vault_get vault_velero_s3_secret |
    xargs -I{} sudo -u garage garage -c "$CONF" key import --yes -n velero "$key_id" {} >/dev/null
fi
g bucket allow --read --write "$BUCKET" --key "$key_id" >/dev/null

echo "==> Check from the bridge address"
curl -sS -o /dev/null -w '    S3 API http://%{remote_ip}:%{remote_port} -> HTTP %{http_code}\n' "http://$S3_BIND/"
g bucket info "$BUCKET" | grep -i -E '^(bucket|size|objects)|^\s*(Size|Objects)' || true
