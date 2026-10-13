#!/usr/bin/env bash
# Prepare the libvirt build host: default storage pool + Rocky 9 base image.
# Idempotent: safe to re-run; skips anything already in place.
set -euo pipefail

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
POOL="${POOL:-default}"
POOL_PATH="${POOL_PATH:-/var/lib/libvirt/images}"

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
