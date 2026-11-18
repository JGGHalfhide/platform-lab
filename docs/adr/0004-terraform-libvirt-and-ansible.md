# 0004. Terraform for VMs, Ansible for everything inside them

Status: accepted (Week 1)

## Context

The build cluster runs as KVM guests on one Arch Linux host
(`qemu:///system`). Every node setting has to be reproducible from the repo
with no manual steps, idempotent, and reusable on a bare-metal node (the
iMac) that no provisioning tool creates.

## Decision

- Terraform with the `dmacvicar/libvirt` provider creates the VMs (shared
  `modules/rocky-vm`, cloud-init for the user and SSH key only, fixed MAC
  with a DHCP reservation for a stable address). Outputs feed the Ansible
  inventory (`make inventory`).
- Ansible does all OS and cluster configuration, one role per concern
  (`base`, `hardening`, `openscap`, `rke2`, `registry_auth`, ...). A second
  run must report `changed=0`. Inventory groups (`build_servers`,
  `airgap_servers`) let the same roles run on the VM and on the iMac.
- Secrets live in Ansible Vault (`ansible/group_vars/all/vault.yml`); the
  Vault key stays outside the repo.
