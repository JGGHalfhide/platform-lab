#!/usr/bin/env bash
# Prepare the libvirt build host: default storage pool, a fixed DHCP address
# for the node, a hosts entry for the registry, and the Rocky 9 base image.
# Idempotent: safe to re-run; skips anything already in place.
set -euo pipefail

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
POOL="${POOL:-default}"
POOL_PATH="${POOL_PATH:-/var/lib/libvirt/images}"

NETWORK="${NETWORK:-default}"
# Must match the Terraform variable mac_address (the Makefile passes both).
NODE_NAME="${NODE_NAME:-build-node-01}"
NODE_MAC="${NODE_MAC:-52:54:00:70:6c:01}"
NODE_IP="${NODE_IP:-192.168.122.10}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.platform-lab.internal}"

ROCKY_BASE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64"
ROCKY_IMAGE="${ROCKY_IMAGE:-Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2}"

virsh_() { virsh -c "$LIBVIRT_URI" "$@"; }

# --- storage pool -----------------------------------------------------------
if ! virsh_ pool-info "$POOL" >/dev/null 2>&1; then
  echo "Defining storage pool '$POOL' at $POOL_PATH"
  virsh_ pool-define-as "$POOL" dir --target "$POOL_PATH"
  virsh_ pool-build "$POOL"
fi
if [[ "$(virsh_ pool-info "$POOL" | awk '/^State:/ {print $2}')" != "running" ]]; then
  echo "Starting storage pool '$POOL'"
  virsh_ pool-start "$POOL"
fi
if [[ "$(virsh_ pool-info "$POOL" | awk '/^Autostart:/ {print $2}')" != "yes" ]]; then
  virsh_ pool-autostart "$POOL"
fi
virsh_ pool-refresh "$POOL" >/dev/null

# --- DHCP reservation -------------------------------------------------------
# The node keeps the same address across rebuilds, so the hosts entry below
# and the registry's image references stay valid.
want="<host mac='$NODE_MAC' name='$NODE_NAME' ip='$NODE_IP'/>"
netxml="$(virsh_ net-dumpxml "$NETWORK")"
if ! grep -qi "mac='$NODE_MAC' name='$NODE_NAME' ip='$NODE_IP'" <<<"$netxml"; then
  # Drop a stale reservation for this name or address first.
  while read -r old; do
    [[ -n "$old" ]] || continue
    echo "Removing stale DHCP reservation: $old"
    virsh_ net-update "$NETWORK" delete ip-dhcp-host "$old" --live --config
  done < <(grep -E "<host [^>]*(name='$NODE_NAME'|ip='$NODE_IP')" <<<"$netxml" | sed 's/^ *//')
  echo "Reserving $NODE_IP for $NODE_NAME ($NODE_MAC) on network '$NETWORK'"
  virsh_ net-update "$NETWORK" add-last ip-dhcp-host "$want" --live --config
fi

# --- hosts entry ------------------------------------------------------------
# The registry is reached through the node's Traefik ingress. This is the one
# step that needs root on the build host; it only runs when the line is missing.
if ! grep -qE "^$NODE_IP[[:space:]]+$REGISTRY_HOST([[:space:]]|\$)" /etc/hosts; then
  if grep -qE "[[:space:]]$REGISTRY_HOST([[:space:]]|\$)" /etc/hosts; then
    echo "/etc/hosts maps $REGISTRY_HOST to another address; fix it by hand" >&2
    exit 1
  fi
  echo "Adding '$NODE_IP $REGISTRY_HOST' to /etc/hosts (sudo)"
  echo "$NODE_IP $REGISTRY_HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# --- base image -------------------------------------------------------------
if virsh_ vol-info --pool "$POOL" "$ROCKY_IMAGE" >/dev/null 2>&1; then
  echo "Base image '$ROCKY_IMAGE' already in pool '$POOL'"
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "Downloading $ROCKY_IMAGE"
curl -fL --progress-bar -o "$workdir/$ROCKY_IMAGE" "$ROCKY_BASE_URL/$ROCKY_IMAGE"
curl -fsSL -o "$workdir/CHECKSUM" "$ROCKY_BASE_URL/CHECKSUM"

expected="$(awk -v f="($ROCKY_IMAGE)" '$1 == "SHA256" && $2 == f {print $4}' "$workdir/CHECKSUM")"
if [[ -z "$expected" ]]; then
  echo "No SHA256 for $ROCKY_IMAGE in CHECKSUM" >&2
  exit 1
fi
echo "$expected  $workdir/$ROCKY_IMAGE" | sha256sum -c -

# Upload through libvirt so no root access to the pool directory is needed.
size="$(stat -c %s "$workdir/$ROCKY_IMAGE")"
virsh_ vol-create-as "$POOL" "$ROCKY_IMAGE" "$size" --format qcow2
virsh_ vol-upload --pool "$POOL" "$ROCKY_IMAGE" "$workdir/$ROCKY_IMAGE"
echo "Base image '$ROCKY_IMAGE' uploaded to pool '$POOL'"
