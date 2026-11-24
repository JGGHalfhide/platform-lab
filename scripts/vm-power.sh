#!/usr/bin/env bash
# Power the lab VMs on and off, one at a time. Both VMs are 20 GiB on a host
# with about 28 GiB usable, so two at once do not fit (local-agents
# docs/resource-plan.md). Terraform starts a VM only when it creates it
# (modules/rocky-vm ignores `running` afterwards); everything else goes
# through here.
#
#   vm-power.sh check <vm>   fail if <vm> may not run now (another lab VM is
#                            running, or the host lacks memory for it)
#   vm-power.sh start <vm>   check, then start <vm> (no-op if running)
#   vm-power.sh stop  <vm>   graceful shutdown, wait until it is off
set -euo pipefail

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
# The VMs that must not run together (Terraform vm_name, rehearsal_vm_name).
LAB_VMS="${LAB_VMS:-build-node-01 airgap-rehearsal}"
# Memory the host keeps for itself on top of the VM (MiB).
HOST_RESERVE_MIB="${HOST_RESERVE_MIB:-2048}"
STOP_TIMEOUT="${STOP_TIMEOUT:-300}"

virsh_() { virsh -c "$LIBVIRT_URI" "$@"; }
# domstate prints a blank line to stdout even when it fails: test its exit code.
state() {
  local s
  if s=$(virsh_ domstate "$1" 2>/dev/null); then printf '%s\n' "$s" | sed -n 1p; else echo undefined; fi
}
die() { echo "vm-power: $*" >&2; exit 1; }

check() {
  local vm="$1" other need avail
  [[ "$(state "$vm")" == running ]] && return 0
  for other in $LAB_VMS; do
    [[ "$other" == "$vm" ]] && continue
    if [[ "$(state "$other")" == running ]]; then
      die "$other is running; stop it first (make vm-stop VM=$other): the lab VMs run one at a time"
    fi
  done
  # Size of the VM if it exists (a new one is checked by Terraform's vars).
  if [[ "$(state "$vm")" != undefined ]]; then
    need=$(( $(virsh_ dominfo "$vm" | awk '/^Max memory:/ {print $3}') / 1024 + HOST_RESERVE_MIB ))
    avail=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
    (( avail >= need )) || die "host has ${avail} MiB available; $vm needs ${need} MiB (VM + ${HOST_RESERVE_MIB} MiB reserve)"
  fi
}

start() {
  local vm="$1"
  [[ "$(state "$vm")" != undefined ]] || die "$vm is not defined (create it with make up / make rehearsal)"
  [[ "$(state "$vm")" == running ]] && { echo "$vm already running"; return 0; }
  check "$vm"
  virsh_ start "$vm"
}

stop() {
  local vm="$1" waited=0
  [[ "$(state "$vm")" == running ]] || { echo "$vm is not running"; return 0; }
  virsh_ shutdown "$vm"
  while [[ "$(state "$vm")" != "shut off" ]]; do
    (( waited >= STOP_TIMEOUT )) && die "$vm still running after ${STOP_TIMEOUT}s"
    sleep 5; waited=$((waited + 5))
  done
  echo "$vm shut off after ${waited}s"
}

[[ $# -eq 2 ]] || die "usage: vm-power.sh check|start|stop <vm>"
case "$1" in
  check|start|stop) "$1" "$2" ;;
  *) die "usage: vm-power.sh check|start|stop <vm>" ;;
esac
