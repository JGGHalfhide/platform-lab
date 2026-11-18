# 0005. Argo CD with an app-of-apps root for the connected cluster

Status: accepted (Week 3)

## Context

Cluster add-ons and policies should be declared in Git and reconciled, not
applied by hand. Options: Argo CD or Flux. The cluster runs every namespace
at Pod Security `restricted`, and the airgapped target has 8 GB of RAM.

## Decision

Argo CD (pinned release manifests plus Kustomize patches in
`gitops/argocd/`), installed once by `make argocd`, then managing itself and
every Application under `gitops/apps/` through the root Application
(`gitops/root.yaml`). Argo CD runs `restricted` with resource limits and
projected tokens, and reads its Redis password from a mounted Secret (STIG
V-242415). Argo CD runs only on the connected build cluster; on the
airgapped target, Zarf deploys the same sources (ADR 0008).
