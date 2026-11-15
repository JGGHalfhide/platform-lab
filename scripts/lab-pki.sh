#!/usr/bin/env bash
# Generate the lab CA and the registry's TLS server certificate.
#
# - CA: ECDSA P-384, 10 years. Its certificate is public and committed at
#   pki/lab-ca.crt; clients trust it through SSL_CERT_FILE (scripts/lib.sh),
#   nothing is installed system-wide.
# - Server: ECDSA P-384, 2 years, SAN registry.platform-lab.internal.
# - Both private keys and the server certificate go into Ansible Vault
#   (vault_lab_ca_key, vault_registry_tls_key, vault_registry_tls_crt). The
#   registry_auth role turns them into the registry-tls Secret.
#
# Run once. Re-running refuses if the vault already has the keys, unless
# FORCE=1 (renewal: rotates the CA too; commit the new pki/lab-ca.crt).
set -euo pipefail
cd "$(dirname "$0")/.."

VAULT=ansible/group_vars/all/vault.yml
VAULT_PASS="${VAULT_PASS:-$HOME/.config/platform-lab/vault-pass}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.platform-lab.internal}"
CA_CRT=pki/lab-ca.crt

av() { ansible-vault "$@" --vault-password-file "$VAULT_PASS"; }

current="$(av view "$VAULT")"
if grep -qE '^vault_(lab_ca_key|registry_tls_(key|crt)):' <<<"$current"; then
  if [[ "${FORCE:-0}" != 1 ]]; then
    echo "Lab PKI already in $VAULT; set FORCE=1 to regenerate" >&2
    exit 1
  fi
  # Drop the old entries (each is a block scalar: key line + indented lines).
  current="$(awk '
    /^vault_(lab_ca_key|registry_tls_(key|crt)):/ {skip=1; next}
    skip && /^[[:space:]]/ {next}
    {skip=0; print}' <<<"$current")"
fi

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

openssl ecparam -name secp384r1 -genkey -noout -out "$work/ca.key"
openssl req -x509 -new -key "$work/ca.key" -sha384 -days 3650 \
  -subj "/O=platform-lab/CN=platform-lab lab CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -out "$work/ca.crt"

openssl ecparam -name secp384r1 -genkey -noout -out "$work/server.key"
openssl req -new -key "$work/server.key" -sha384 \
  -subj "/O=platform-lab/CN=$REGISTRY_HOST" -out "$work/server.csr"
cat >"$work/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:$REGISTRY_HOST
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
  -CAcreateserial -sha384 -days 730 -extfile "$work/server.ext" -out "$work/server.crt"
openssl verify -CAfile "$work/ca.crt" "$work/server.crt"

block() { printf '%s: |\n' "$1"; sed 's/^/  /' "$2"; }
{
  printf '%s\n' "$current"
  block vault_lab_ca_key "$work/ca.key"
  block vault_registry_tls_key "$work/server.key"
  block vault_registry_tls_crt "$work/server.crt"
} | av encrypt --output "$work/vault.new" -
# Check the new vault decrypts and parses before replacing the old one.
av view "$work/vault.new" | python -c 'import sys, yaml; yaml.safe_load(sys.stdin)'
cp "$work/vault.new" "$VAULT"

mkdir -p pki
cp "$work/ca.crt" "$CA_CRT"
echo "Lab CA: $CA_CRT"
openssl x509 -in "$CA_CRT" -noout -subject -enddate -fingerprint -sha256
echo "Server certificate for $REGISTRY_HOST stored in $VAULT"
openssl x509 -in "$work/server.crt" -noout -enddate
