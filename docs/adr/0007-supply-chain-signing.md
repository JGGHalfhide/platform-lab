# 0007. Image publishing: SBOM, scan gate and cosign key-pair signatures without a transparency log

Status: accepted (Week 4)

## Context

Every image the platform runs from its own registry must have an SBOM, pass
a vulnerability gate, and be verifiably signed, and the signature has to be
verifiable on the airgapped target. Keyless signing (Fulcio) and the public
Rekor transparency log both need internet access at verification time
unless a private Sigstore stack is run. cosign v3 stores signatures as OCI
1.1 referrer bundles by default; Kyverno 1.19 did not find signatures in
that format in testing, while tag-based `.sig`/`.att` artifacts are the
format Kyverno and Zarf have supported longest.

## Decision

- `make image` pulls the whole upstream index (digest preserved), generates
  SPDX and CycloneDX SBOMs with Syft, scans with Trivy and fails on any
  fixable CRITICAL finding (documented exceptions in `.trivyignore.yaml`),
  pushes over TLS, then signs the index digest and attaches the SPDX SBOM
  as an attestation.
- Signing uses a local cosign key pair: private key outside the repo,
  password in Vault, public key at `pki/cosign.pub`. No Rekor upload; the
  tag-based signature format (`--new-bundle-format=false`).
- CI re-runs the SBOM and scan gate on the deployed digests
  (`.github/workflows/supply-chain.yml`); signing stays in the lab.
