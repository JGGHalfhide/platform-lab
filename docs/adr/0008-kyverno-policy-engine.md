# 0008. Kyverno for admission policy and image verification

Status: accepted (Weeks 4-5)

## Context

Pod Security admission (built into RKE2's CIS profile) covers the Pod
Security Standards but not image provenance, registry allow-lists, tag
pinning, resource requirements, labels or Secrets in environment
variables. Options: OPA Gatekeeper (Rego) or Kyverno. Image signature
verification with cosign is built into Kyverno; Gatekeeper needs an
external data provider for it. In Kyverno 1.19, `ClusterPolicy` is
deprecated in favour of CEL-based `ValidatingPolicy` and
`ImageValidatingPolicy`.

## Decision

Kyverno (pinned chart, restricted Pod Security, no token automount) via
Argo CD. Policies are `ValidatingPolicy` / `ImageValidatingPolicy` (CEL) in
`gitops/policies/`, tested offline with `make policy-test`, run in Audit
first and then switched to Enforce. Exceptions are `PolicyException`
resources, allowed only in the `kyverno` namespace and scoped to named
workloads. Pod Security admission stays the first layer; Kyverno is the
second (`docs/policy-map.md`).
