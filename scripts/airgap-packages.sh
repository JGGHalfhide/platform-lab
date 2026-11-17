#!/usr/bin/env bash
# Build and sign the Zarf packages for the airgapped cluster.
#
#   scripts/airgap-packages.sh [package...]     (or: make airgap-packages)
#
# Packages (zarf/<name>/zarf.yaml): platform, policies, sample-app, monitoring
# by default.
# Output: build/airgap/packages/zarf-package-<name>-amd64-<version>.tar.zst.
#
# - Images are pulled from upstream registries and, for the sample app, from
#   the build cluster's registry over TLS (lab CA via registry_env), so that
#   the cosign signatures made by `make image` travel with them.
# - Each package is signed with the lab cosign key (the same key that signs
#   images; password from Vault through COSIGN_PASSWORD, which Zarf's signer
#   reads) and verified against pki/cosign.pub. The target checks the
#   signature again on deploy (`zarf package deploy --key`), which covers the
#   copy over scp/USB.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OUT="${OUT:-$REPO_ROOT/build/airgap/packages}"
COSIGN_KEY="${COSIGN_KEY:-$HOME/.config/platform-lab/cosign.key}"
packages=("$@")
[[ ${#packages[@]} -gt 0 ]] || packages=(platform policies sample-app monitoring)

mkdir -p "$OUT" "$REPO_ROOT/build/logs"
trap registry_env_cleanup EXIT
registry_env
COSIGN_PASSWORD="$(vault_get vault_cosign_password)"
export COSIGN_PASSWORD

for p in "${packages[@]}"; do
  echo "==> zarf/$p"
  start=$(date +%s)
  log="$REPO_ROOT/build/logs/zarf-create-$p.log"
  if ! zarf package create "$REPO_ROOT/zarf/$p" --output "$OUT" \
      --signing-key "$COSIGN_KEY" --confirm --no-color >"$log" 2>&1; then
    tail -20 "$log" >&2
    echo "zarf package create failed for $p (log: $log)" >&2
    exit 1
  fi
  file="$(ls -t "$OUT"/zarf-package-"$p"-*.tar.zst | head -1)"
  zarf package inspect definition "$file" --key "$REPO_ROOT/pki/cosign.pub" \
    --no-color >/dev/null 2>&1 || { echo "signature check failed: $file" >&2; exit 1; }
  echo "    $(basename "$file") $(du -h "$file" | cut -f1), signed, $(( $(date +%s) - start ))s"
done

(cd "$OUT" && sha256sum zarf-package-*.tar.zst >SHA256SUMS)
