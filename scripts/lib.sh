# Shared helpers for the supply-chain scripts. Source it; don't run it.
#
# registry_env: trust the lab CA and log in to the in-cluster registry with a
# throwaway Docker config, so no credentials persist on the build host.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${REGISTRY:-registry.platform-lab.internal}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
VAULT_PASS="${VAULT_PASS:-$HOME/.config/platform-lab/vault-pass}"
SYSTEM_CA_BUNDLE="${SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

# Read one top-level value from the Ansible Vault.
vault_get() {
  ansible-vault view --vault-password-file "$VAULT_PASS" \
    "$REPO_ROOT/ansible/group_vars/all/vault.yml" |
    python -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)[sys.argv[1]], end="")' "$1"
}

# Sets SSL_CERT_FILE (system CAs + lab CA) and DOCKER_CONFIG (temp dir with
# registry credentials). Go tools (crane, cosign, syft, trivy) honor both.
# Callers clean up with registry_env_cleanup (set an EXIT trap).
registry_env() {
  _registry_tmp="$(mktemp -d)"
  chmod 700 "$_registry_tmp"
  cat "$SYSTEM_CA_BUNDLE" "$REPO_ROOT/pki/lab-ca.crt" >"$_registry_tmp/ca-bundle.pem"
  export SSL_CERT_FILE="$_registry_tmp/ca-bundle.pem"
  export DOCKER_CONFIG="$_registry_tmp/docker"
  # crane warns that the config is unencrypted; it is a 0700 temp dir that
  # registry_env_cleanup removes.
  vault_get vault_zot_admin_password |
    crane auth login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 ||
    { echo "Registry login to $REGISTRY failed" >&2; return 1; }
}

registry_env_cleanup() {
  [[ -n "${_registry_tmp:-}" ]] && rm -rf "$_registry_tmp"
}

# Map an upstream reference to its path in the in-cluster registry, keeping
# the repository path (Zarf does the same): docker.io/library/alpine:3.22 and
# alpine:3.22 -> library/alpine; quay.io/argoproj/argocd -> argoproj/argocd.
registry_repo() {
  local ref="${1%%@*}" first rest
  # A tag is whatever follows the last ':' if that part has no '/' (otherwise
  # the ':' belongs to a registry port).
  [[ "${ref##*:}" != */* && "$ref" == *:* ]] && ref="${ref%:*}"
  first="${ref%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    rest="${ref#*/}"
  else
    rest="$ref"
  fi
  [[ "$rest" == */* ]] || rest="library/$rest"
  printf '%s\n' "$rest"
}
