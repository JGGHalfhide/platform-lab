#!/usr/bin/env bash
# Run kube-bench (RKE2 CIS benchmark) as a Job, save its output, clean up.
# Usage: scripts/kube-bench.sh [output-file]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-docs/scans/kube-bench.txt}"
NAMESPACE="scripts/kube-bench/namespace.yaml"
MANIFEST="scripts/kube-bench/job.yaml"
k() { kubectl --kubeconfig kubeconfig "$@"; }

cleanup() { k delete -f "$MANIFEST" -f "$NAMESPACE" --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT

# Start from a clean slate in case a previous run was interrupted.
k delete -f "$MANIFEST" -f "$NAMESPACE" --ignore-not-found --wait=true >/dev/null
k apply -f "$NAMESPACE"
# Wait for the default service account so job.yaml updates it (no create race).
for _ in $(seq 1 30); do k -n kube-bench get serviceaccount default >/dev/null 2>&1 && break; sleep 1; done
k apply -f "$MANIFEST"

echo "Waiting for kube-bench to finish..."
k -n kube-bench wait --for=condition=Complete job/kube-bench --timeout=300s ||
  { k -n kube-bench logs job/kube-bench || true; echo "kube-bench did not complete" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
k -n kube-bench logs job/kube-bench >"$OUT"
echo "Saved $OUT"
grep -E '^[0-9]+ checks (PASS|FAIL|WARN|INFO)' "$OUT" | tail -4
