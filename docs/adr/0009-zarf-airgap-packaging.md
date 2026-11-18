# 0009. Zarf for the airgapped deploy; RKE2 from staged RPMs

Status: accepted (Week 6; RKE2 install method 11/16)

## Context

The target has no internet access. Everything it runs (RKE2, images, Helm
charts, manifests, cosign signatures) has to be carried over as files, and
images have to land in a registry on the target that Kyverno can verify
against. Argo CD does not fit in the target's 8 GB of RAM next to the
platform. For RKE2 itself, the upstream `install.sh` airgap mode installs a
tarball, while the build node uses the RPM packages with `rke2-selinux`.

## Decision

- Zarf packages (`zarf/platform`, `zarf/policies`, `zarf/sample-app`,
  `zarf/monitoring`) built on the connected host from the same sources as
  `gitops/`, signed with the lab cosign key, and verified on deploy
  (`--verify=always`). `zarf init` provides the target's registry and the
  agent that rewrites image references to it. cosign `.sig`/`.att`
  artifacts are listed in the packages so signatures survive the transfer.
- RKE2 installs from staged RPMs and its images tarball through the same
  `rke2` role (airgap mode), so both clusters have the same package layout
  and SELinux policy. local-path-provisioner is bootstrapped through RKE2's
  manifests directory, because Zarf's registry needs a StorageClass.
