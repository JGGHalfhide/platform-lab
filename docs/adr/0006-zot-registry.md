# 0006. Zot as the in-cluster registry

Status: accepted (Week 3)

## Context

The platform needs an in-cluster OCI registry that holds images, cosign
signatures and SBOM attestations, runs under Pod Security `restricted`, and
fits on a single small node next to the rest of the stack. Options: Harbor
or Zot.

- Harbor is a multi-service application (core, portal, registry,
  jobservice, PostgreSQL, Redis, optional Trivy), with a large memory
  footprint for one node.
- Zot is a single OCI-native binary that stores OCI artifacts as-is, so
  cosign `.sig`/`.att` tags and referrers need no extra setup.

## Decision

Zot (pinned chart and image) through Argo CD, on a local-path volume, as
UID 65532 with a restricted security context. Anonymous read; push only as
`admin` with an htpasswd Secret built from Vault. TLS ingress
`registry.platform-lab.internal` with a certificate from the lab CA; the
node pulls through NodePort 30500 on localhost.
