#!/usr/bin/env bash
# Pull an upstream image, generate its SBOM, scan it, and push it to the
# in-cluster registry over TLS.
#
#   scripts/publish-image.sh <image-ref>      (or: make image IMAGE=<image-ref>)
#
# 1. Resolve the reference to a digest and pull the whole index (all platforms)
#    as an OCI layout, so the pushed digest equals the upstream one.
# 2. Syft: SPDX and CycloneDX SBOMs for SCAN_PLATFORM.
# 3. Trivy: full report for SCAN_PLATFORM, then the gate: fail on any
#    vulnerability at GATE_SEVERITY that has a fix. Documented exceptions go
#    in .trivyignore.yaml at the repo root. GATE_SEVERITY=none skips the gate.
# 4. Push to $REGISTRY/<repo>:<tag> and check the digest is unchanged.
# 5. cosign: sign the index digest and attach the SPDX SBOM as an attestation
#    (type spdxjson), with the key from scripts/cosign-keygen.sh, then verify
#    both against pki/cosign.pub. No transparency log: the airgapped target
#    can't reach Rekor. Signatures use cosign's tag-based layout
#    (sha256-<digest>.sig/.att) rather than v3's default OCI referrers
#    bundle: it is the format Kyverno and Zarf have supported longest.
#    SIGN=0 skips this step.
#
# PUSH=0 stops after the gate (steps 1-3 only; no registry, no key): used by
# CI (.github/workflows/supply-chain.yml) to re-check the deployed digests.
#
# Outputs land in build/images/<repo>/<digest>/ (gitignored); the last line
# printed is the pushed reference, pinned by digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SCAN_PLATFORM="${SCAN_PLATFORM:-linux/amd64}"
GATE_SEVERITY="${GATE_SEVERITY:-CRITICAL}"
SIGN="${SIGN:-1}"
PUSH="${PUSH:-1}"
COSIGN_KEY="${COSIGN_KEY:-$HOME/.config/platform-lab/cosign.key}"

src="${1:?usage: $0 <image-ref>}"
repo="$(registry_repo "$src")"

# Tag: the source tag, or the digest-derived one if pulling by digest only.
ref_nodigest="${src%%@*}"
if [[ "${ref_nodigest##*:}" != */* && "$ref_nodigest" == *:* ]]; then
  tag="${ref_nodigest##*:}"
else
  tag=""
fi

echo "==> Resolving $src"
digest="$(crane digest "$src")"
if [[ "$src" == *@* && "${src#*@}" != "$digest" ]]; then
  echo "Digest mismatch: asked for ${src#*@}, registry returned $digest" >&2
  exit 1
fi
[[ -n "$tag" ]] || tag="sha256-${digest#sha256:}"
pinned="${src%%@*}@$digest"
echo "    $pinned"

out="$REPO_ROOT/build/images/$repo/${digest#sha256:}"
mkdir -p "$out"
oci="$out/oci"

if [[ -f "$oci/index.json" ]]; then
  echo "==> Using cached OCI layout $oci"
else
  echo "==> Pulling all platforms"
  rm -rf "$oci"
  crane pull --format=oci --platform=all "$pinned" "$oci"
fi

echo "==> SBOM (syft, $SCAN_PLATFORM)"
syft scan "oci-dir:$oci" --platform "$SCAN_PLATFORM" -q \
  --source-name "$repo" --source-version "$tag" \
  -o "spdx-json=$out/sbom.spdx.json" -o "cyclonedx-json=$out/sbom.cdx.json"
python - "$out/sbom.spdx.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"    {len(d['packages'])} packages ({d['spdxVersion']})")
EOF

echo "==> Vulnerability scan (trivy, $SCAN_PLATFORM)"
# Exceptions: .trivyignore.yaml (path-scoped, with a statement per entry).
# Suppressed findings stay in the reports (--show-suppressed) but are not
# counted by the gate, which reads only the unsuppressed Vulnerabilities.
ignorefile="$REPO_ROOT/.trivyignore.yaml"
trivy_args=(image --input "$oci" --platform "$SCAN_PLATFORM" -q)
if [[ -f "$ignorefile" ]]; then
  trivy_args+=(--ignorefile "$ignorefile" --show-suppressed)
else
  trivy_args+=(--ignorefile "")
fi
trivy "${trivy_args[@]}" --format json -o "$out/trivy.json"
convert_args=(--format table -o "$out/trivy.txt")
[[ -f "$ignorefile" ]] && convert_args+=(--show-suppressed)
trivy convert "${convert_args[@]}" "$out/trivy.json"
python - "$out/trivy.json" <<'EOF' | tee "$out/trivy-summary.txt"
import json, sys
from collections import Counter
d = json.load(open(sys.argv[1]))
all_, fixable = Counter(), Counter()
for r in d.get("Results", []):
    for v in r.get("Vulnerabilities") or []:
        all_[v["Severity"]] += 1
        if v.get("FixedVersion"):
            fixable[v["Severity"]] += 1
order = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
print("    " + ", ".join(f"{s} {all_[s]} ({fixable[s]} fixable)" for s in order))
suppressed = sum(len(r.get("ExperimentalModifiedFindings") or []) for r in d.get("Results", []))
if suppressed:
    print(f"    {suppressed} suppressed by .trivyignore.yaml (listed in trivy.txt)")
EOF

if [[ "$GATE_SEVERITY" != none ]]; then
  echo "==> Gate: no fixable $GATE_SEVERITY vulnerabilities"
  if ! python - "$out/trivy.json" "$GATE_SEVERITY" "$repo:$tag" >"$out/trivy-gate.txt" <<'EOF'; then
import json, sys
d = json.load(open(sys.argv[1]))
sev = set(sys.argv[2].split(","))
hits = [(r["Target"], v) for r in d.get("Results", [])
        for v in r.get("Vulnerabilities") or []
        if v["Severity"] in sev and v.get("FixedVersion")]
for target, v in hits:
    print(f"{v['VulnerabilityID']:<20} {v['Severity']:<9} {v['PkgName']} "
          f"{v['InstalledVersion']} -> {v['FixedVersion']}  "
          f"({sys.argv[3]}{target[target.rfind(' ('):] if ' (' in target else ''})")
sys.exit(1 if hits else 0)
EOF
    cat "$out/trivy-gate.txt"
    echo "Gate failed for $pinned: see $out/trivy-gate.txt." >&2
    echo "Rebuild/upgrade the image, or document an exception in .trivyignore.yaml." >&2
    exit 1
  fi
  echo "    passed"
fi

if [[ "$PUSH" == 0 ]]; then
  echo "==> PUSH=0: not pushing or signing; outputs in $out"
  echo "$pinned"
  exit 0
fi

echo "==> Pushing to $REGISTRY/$repo:$tag"
trap registry_env_cleanup EXIT
registry_env
crane push "$oci" "$REGISTRY/$repo:$tag" >/dev/null
pushed="$(crane digest "$REGISTRY/$repo:$tag")"
if [[ "$pushed" != "$digest" ]]; then
  echo "Pushed digest $pushed differs from upstream $digest" >&2
  exit 1
fi

target="$REGISTRY/$repo@$digest"
verify_flags=(--key "$REPO_ROOT/pki/cosign.pub" --insecure-ignore-tlog --new-bundle-format=false)
verified() {
  cosign verify "${verify_flags[@]}" "$target" >"$out/cosign-verify.json" 2>/dev/null &&
    cosign verify-attestation "${verify_flags[@]}" --type spdxjson "$target" \
      >"$out/cosign-verify-attestation.json" 2>/dev/null
}
# Re-running must not stack attestations (each run's SBOM differs in its
# timestamp and ID), so skip when a valid signature and SBOM already exist.
if [[ "$SIGN" == 1 ]] && verified; then
  echo "==> Already signed with an SBOM attestation (pki/cosign.pub); skipping cosign"
elif [[ "$SIGN" == 1 ]]; then
  echo "==> Signing and attesting the SBOM (cosign)"
  COSIGN_PASSWORD="$(vault_get vault_cosign_password)"
  export COSIGN_PASSWORD
  cosign_flags=(--yes --key "$COSIGN_KEY" --new-bundle-format=false
    --use-signing-config=false --tlog-upload=false)
  cosign sign "${cosign_flags[@]}" "$target" 2>"$out/cosign-sign.log" ||
    { cat "$out/cosign-sign.log" >&2; exit 1; }
  cosign attest "${cosign_flags[@]}" --type spdxjson \
    --predicate "$out/sbom.spdx.json" "$target" 2>"$out/cosign-attest.log" ||
    { cat "$out/cosign-attest.log" >&2; exit 1; }
  unset COSIGN_PASSWORD

  verified || { echo "Signature or SBOM attestation verification failed for $target" >&2; exit 1; }
  echo "    signature and SBOM attestation verified"
fi

printf '%s\n' "$pinned" >"$out/source"
printf '%s\n' "$REGISTRY/$repo:$tag@$digest" | tee "$out/pushed"
