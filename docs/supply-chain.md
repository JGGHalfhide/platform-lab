# Supply chain

Every image the platform runs from the in-cluster registry is scanned, has an
SBOM, and is signed; Kyverno rejects unsigned images at admission.

## Publishing an image

`make image IMAGE=<ref>` (`scripts/publish-image.sh`):

| Step | Tool | Detail |
|---|---|---|
| Resolve and pull | crane | Reference resolved to a digest; the whole index (all platforms) pulled as an OCI layout, so the pushed digest equals upstream. |
| SBOM | Syft 1.55.0 | SPDX 2.3 and CycloneDX JSON for `linux/amd64`. |
| Scan and gate | Trivy 0.76.2 | Full JSON and table report; fails on any CRITICAL finding that has a fix (`GATE_SEVERITY`). Documented exceptions go in `.trivyignore`. |
| Push | crane | Over TLS to `registry.platform-lab.internal` (lab CA, `pki/lab-ca.crt`), with a throwaway login; pushed digest checked against upstream. |
| Sign and attest | cosign 3.1.3 | Signature on the index digest and the SPDX SBOM as an in-toto attestation (`spdxjson`), lab key (`pki/cosign.pub`), no transparency log. Both verified before the script succeeds; skipped if already valid. |

Outputs (OCI layout, SBOMs, scan reports, verification results) land in
`build/images/<repo>/<digest>/`, which is not committed.

Signatures use cosign's tag-based layout (`sha256-<digest>.sig` / `.att`)
rather than cosign v3's default OCI 1.1 referrer bundles, for Kyverno and
Zarf compatibility. In a test, Kyverno 1.19 did not find referrer-bundle
signatures at all.

Images published so far:

| Image | Packages | CRITICAL / HIGH (fixable) | Signed |
|---|---|---|---|
| `library/alpine:3.22` | 17 | 0 / 0 | yes |
| `library/busybox:1.37.0` | 2 | 0 / 0 | yes |
| `library/busybox:1.36.1` | - | - | no (unsigned test image, `SIGN=0`) |
| `library/alpine:3.21` | - | - | no (format test image, signatures removed) |
| `nginx:1.25.0` | - | 7 fixable CRITICAL | blocked by the gate, not pushed |
| `stefanprodan/podinfo:6.17.0` (sample app, Week 6) | 123 | 0 / 3 | yes |
| `library/postgres:17.12-alpine3.24` (sample app, Week 6) | 51 | 0 / 0 after the `gosu` exception (26 suppressed) | yes |

### Scan exceptions

Exceptions live in `.trivyignore.yaml` at the repo root, one entry per CVE,
each scoped to the file it applies to (`paths`) with a statement. Trivy runs
with `--show-suppressed`: suppressed findings still appear in each image's
`trivy.txt` / `trivy.json` (`ExperimentalModifiedFindings`) and in the
summary line, but the gate does not count them.

| Image | File | Findings | Why it is not exploitable here |
|---|---|---|---|
| `library/postgres:17.12-alpine3.24` | `usr/local/bin/gosu` | 1 CRITICAL, 25 HIGH, all Go stdlib 1.24.6 | The image entrypoint runs gosu only when the container starts as root, to drop to the postgres user. The sample app runs as UID 70 from the start, and root is rejected by the restricted Pod Security level and Kyverno, so gosu is never executed. |

On the airgapped cluster, signed images keep their signatures through Zarf;
see `docs/airgap-runbook.md`.

## Admission policy

`gitops/policies/verify-platform-images.yaml`, a Kyverno
`ImageValidatingPolicy` (Kyverno v1.19.2), deployed by the `policies` Argo
CD Application. For every pod (and, through autogen, every workload) using an
image from `127.0.0.1:30500/*`:

1. The image must be pinned by digest.
2. The image must carry a cosign signature that verifies with `pki/cosign.pub`.

Kyverno cannot reach `127.0.0.1:30500` from its own pod, and it prefetches
every image the policy matches from the reference as written. The policy
therefore matches a rewritten form instead: a custom image extractor lists
each `127.0.0.1:30500/<repo>@<digest>` as
`zot.zot.svc.cluster.local:5000/<repo>@<digest>`, the same registry through
its Service. That hop is plain HTTP inside the cluster; the digest and the
signature carry the integrity, so the transport does not need to be trusted.

Limits:

- **SBOM attestations are not checked at admission.** Kyverno 1.19 and 1.20
  fail every tag-based attestation when the transparency log is ignored
  (kyverno/kyverno#17109; the signature path handles it). `make image`
  verifies the attestation at publish time. Re-add the check when the fix
  ships.
- **Images from other registries are not matched yet.** The Week 5 "trusted
  registries only" policy closes that gap.

## Admission test

Full output: `docs/scans/week4-admission-test.txt`.

| Case | Result | Message |
|---|---|---|
| Signed image, pinned by digest | admitted, ran | |
| Unsigned image (`SIGN=0`) | rejected | image is not signed with the platform-lab cosign key (pki/cosign.pub); publish it with `make image` |
| Signed image referenced by tag only | rejected | images from the platform registry must be pinned by digest |
| Deployment with the unsigned image | rejected at the Deployment | same as unsigned |
