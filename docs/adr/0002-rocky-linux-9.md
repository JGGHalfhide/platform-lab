# 0002. Rocky Linux 9 on every node, including the airgapped target

Status: accepted (VMs Week 1; iMac 11/14, replacing Fedora)

## Context

The guest OS has to be scannable against a published DISA STIG profile,
supported by RKE2's SELinux policy, and available as a cloud-init image for
the libvirt VMs. The iMac was first planned to run Fedora.

- scap-security-guide has a STIG profile for RHEL 9 and derivatives; it has
  none for Fedora (CIS, OSPP, PCI-DSS and others only).
- `rke2-selinux` packages target EL.
- Rocky Linux 9 publishes a GenericCloud qcow2 image (cloud-init) and a
  minimal ISO for bare metal.

## Decision

Rocky Linux 9 on the build VMs (GenericCloud image, pinned and verified against Rocky's published SHA-256) and
on the iMac (minimal install). The same `base`, `hardening` and `rke2` roles
and the same STIG scan apply to both clusters. The one STIG high finding
this leaves (`installed_OS_is_vendor_supported`) is a documented exception.
