#!/usr/bin/env bash
# Generate the cosign signing key pair (once).
#
# - Private key: $COSIGN_KEY (default ~/.config/platform-lab/cosign.key),
#   outside the repo, mode 0600. Back it up with the vault password file:
#   losing it means re-signing every image with a new key.
# - Key password: random, stored in Ansible Vault as vault_cosign_password;
#   the signing script reads it from there.
# - Public key: pki/cosign.pub (committed; Kyverno verifies against it).
#
# Refuses to run if either the key or the vault entry already exists.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

COSIGN_KEY="${COSIGN_KEY:-$HOME/.config/platform-lab/cosign.key}"
PUB=pki/cosign.pub
VAULT=ansible/group_vars/all/vault.yml

av() { ansible-vault "$@" --vault-password-file "$VAULT_PASS"; }

current="$(av view "$VAULT")"
if [[ -e "$COSIGN_KEY" ]] || grep -q '^vault_cosign_password:' <<<"$current"; then
  echo "cosign key ($COSIGN_KEY) or vault_cosign_password already exists; not overwriting" >&2
  exit 1
fi

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

COSIGN_PASSWORD="$(openssl rand -base64 33 | tr -d '\n/+=')"
export COSIGN_PASSWORD
(cd "$work" && cosign generate-key-pair --output-key-prefix cosign >/dev/null)

# Vault first: a key without its password would be useless.
{
  printf '%s\n' "$current"
  printf 'vault_cosign_password: "%s"\n' "$COSIGN_PASSWORD"
} | av encrypt --output "$work/vault.new" -
av view "$work/vault.new" | python -c 'import sys, yaml; assert yaml.safe_load(sys.stdin)["vault_cosign_password"]'
cp "$work/vault.new" "$VAULT"

install -m 0600 "$work/cosign.key" "$COSIGN_KEY"
mkdir -p pki
cp "$work/cosign.pub" "$PUB"

echo "Private key: $COSIGN_KEY (back it up; never commit it)"
echo "Public key:  $PUB"
openssl pkey -pubin -in "$PUB" -noout -text | head -1
