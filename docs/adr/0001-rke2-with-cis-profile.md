# 0001. RKE2 with the CIS profile as the Kubernetes distribution

Status: accepted (Week 1, 10/13)

## Context

The platform has to pass DISA STIG and CIS checks on a single small node,
run with SELinux enforcing, and install with no internet access on the
target. Options considered: kubeadm, k3s, RKE2.

- kubeadm leaves every hardening setting (admission configuration, Pod
  Security, audit logging, encryption at rest, file permissions) to the
  operator, and has no airgap install path of its own.
- k3s is light, but its defaults target the edge rather than compliance;
  the CIS settings have to be added by hand.
- RKE2 ships a `profile: cis` setting that applies the CIS Kubernetes
  benchmark controls (Pod Security admission at `restricted`, protected
  kernel defaults, an `etcd` user, audit policy, Secrets encryption), has
  an `rke2-selinux` policy package for EL9, an airgap install from RPMs and
  an images tarball, and a CIS benchmark profile in kube-bench.

## Decision

Use RKE2 (pinned, `dnf versionlock`) with `profile: cis` and SELinux
enforcing on every node. Measure it with kube-bench's RKE2 CIS 1.9 profile.
