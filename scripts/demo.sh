#!/usr/bin/env bash
# Demo: build the cluster from scratch, publish a signed image, and show
# Kyverno admitting a compliant pod and rejecting non-compliant ones.
#
#   scripts/demo.sh           # full run: make up, then the policy demo
#   SKIP_UP=1 scripts/demo.sh # policy demo only, against a running cluster
#
# Run from the repo root. Record with: asciinema rec -c scripts/demo.sh demo.cast
set -euo pipefail

export KUBECONFIG="$PWD/kubeconfig"
NS=demo

step() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; sleep 1; }
run() { printf '\033[1;32m$ %s\033[0m\n' "$*"; "$@"; }
# Expect a command to fail (an admission rejection) and keep going.
reject() { printf '\033[1;32m$ %s\033[0m\n' "$*"; if "$@"; then echo "UNEXPECTED: admitted" >&2; exit 1; fi; }

pod() { # name image
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels:
    app.kubernetes.io/name: $1
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $2
      command: ["sh", "-c", "echo hello from a signed image"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
}

step "Commit under test"
run git log --oneline -1

if [[ -z "${SKIP_UP:-}" ]]; then
  step "Build from scratch: host setup, VM, hardening, RKE2 (CIS), Argo CD"
  start=$(date +%s)
  make up </dev/null
  echo "make up: $(( $(date +%s) - start ))s"
fi

step "Cluster"
run make verify
step "Waiting for Argo CD to sync the platform apps"
for _ in $(seq 60); do
  bad=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' | grep -vc '^Synced/Healthy$' || true)
  [[ "$bad" == 0 ]] && break
  sleep 10
done
run kubectl -n argocd get applications

step "Publish images: SBOM (Syft), scan gate (Trivy), push, sign (cosign)"
make image IMAGE=docker.io/library/busybox:1.37.0 | tee /dev/stderr | tail -1 >build/demo-signed
SIGN=0 make image IMAGE=docker.io/library/busybox:1.36.1 | tail -1 >build/demo-unsigned
signed=$(<build/demo-signed)
unsigned=$(<build/demo-unsigned)
# Pods pull through the node-local NodePort, as the platform manifests do.
signed=127.0.0.1:30500/${signed#*/}
unsigned=127.0.0.1:30500/${unsigned#*/}

kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "1. Compliant pod: signed image, digest-pinned, restricted, labelled, with resources"
pod signed-app "$signed" | run kubectl apply -f -
run kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/signed-app --timeout=120s
run kubectl -n $NS logs signed-app

step "2. Same pod with an unsigned image: rejected by the signature check"
pod unsigned-app "$unsigned" | reject kubectl apply -f -

step "3. Upstream nginx:latest, no label, no resources: rejected"
cat <<EOF | reject kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: $NS
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: nginx
      image: docker.io/library/nginx:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
EOF

step "Clean up"
run kubectl delete namespace $NS --wait=false
