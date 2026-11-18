# 0003. Keep firewalld on alongside RKE2's Canal CNI

Status: accepted (Week 1, 10/13)

## Context

RKE2's documentation recommends disabling firewalld, because its rules can
interfere with the CNI's own iptables/nftables rules. The RHEL 9 STIG
requires a host firewall that is active and denies by default. Options:
(a) keep firewalld on, open only RKE2's ports, and put the CNI interfaces
and the pod and service CIDRs in the `trusted` zone; (b) disable firewalld
and record a STIG exception.

## Decision

Option (a): firewalld stays on. RKE2 ports are opened in `public`;
10.42.0.0/16, 10.43.0.0/16 and the CNI interfaces are `trusted`;
NetworkManager ignores the CNI interfaces. Accepted after pod-to-pod,
Service, DNS, egress and NodePort traffic were verified with firewalld on,
before and after hardening. Airgap egress blocking (Week 6) is built on the
same firewalld, as policies.
