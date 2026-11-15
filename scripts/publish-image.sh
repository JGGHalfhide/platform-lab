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
#    in .trivyignore at the repo root. GATE_SEVERITY=none skips the gate.
# 4. Push to $REGISTRY/<repo>:<tag> and check the digest is unchanged.
#
# Outputs land in build/images/<repo>/<digest>/ (gitignored); the last line
# printed is the pushed reference, pinned by digest.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SCAN_PLATFORM="${SCAN_PLATFORM:-linux/amd64}"
GATE_SEVERITY="${GATE_SEVERITY:-CRITICAL}"

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
ignorefile="$REPO_ROOT/.trivyignore"
trivy_args=(image --input "$oci" --platform "$SCAN_PLATFORM" -q)
[[ -f "$ignorefile" ]] && trivy_args+=(--ignorefile "$ignorefile")
trivy "${trivy_args[@]}" --format json -o "$out/trivy.json"
trivy convert --format table -o "$out/trivy.txt" "$out/trivy.json"
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
    echo "Rebuild/upgrade the image, or document an exception in .trivyignore." >&2
    exit 1
  fi
  echo "    passed"
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

printf '%s\n' "$pinned" >"$out/source"
printf '%s\n' "$REGISTRY/$repo:$tag@$digest" | tee "$out/pushed"
