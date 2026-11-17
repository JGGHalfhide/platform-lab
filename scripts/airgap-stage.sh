#!/usr/bin/env bash
# Stage everything the airgapped node needs, on the connected build host.
#
#   scripts/airgap-stage.sh        (or: make airgap-stage)
#
# Output in build/airgap/ (gitignored), carried to the target by Ansible
# (rke2 role, airgap mode) or by hand (scp/USB):
#
#   rke2/rpms/       rke2-common, rke2-server, rke2-selinux: the exact
#                    versions the build node runs, from rpm.rancher.io (signed;
#                    the target checks the signatures against the Rancher key)
#   rke2/images/     RKE2 core and Canal image tarballs (GitHub release,
#                    checked against the release's sha256sum file)
#   bootstrap/       local-path-provisioner, rendered from
#                    gitops/local-path-storage, and its two images as an OCI
#                    archive that RKE2 imports at start. The Zarf registry
#                    needs a default StorageClass before `zarf init`, so this
#                    one component cannot come through Zarf.
#   zarf/            Zarf CLI and init package (pinned, checksum-checked)
#   SHA256SUMS       checksums of every staged file, checked again on the target
#
# Idempotent: files already present with the right checksum are kept.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OUT="${OUT:-$REPO_ROOT/build/airgap}"
ZARF_VERSION="${ZARF_VERSION:-v0.89.0}"
ARCH=amd64

# Versions come from the rke2 role, so the target runs what the build node runs.
defaults="$REPO_ROOT/ansible/roles/rke2/defaults/main.yml"
yq_() { python -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]], end="")' "$defaults" "$1"; }
rke2_minor="$(yq_ rke2_minor)"
rke2_version="$(yq_ rke2_version)"           # 1.36.5~rke2r1 (RPM form)
rke2_selinux_version="$(yq_ rke2_selinux_version)"
rke2_repo_base="$(yq_ rke2_repo_base)"
rke2_tag="v${rke2_version/\~/+}"              # v1.36.5+rke2r1 (release tag)

mkdir -p "$OUT"/{rke2/rpms,rke2/images,bootstrap,zarf}

# fetch URL DEST SHA256: download unless DEST already has the checksum.
fetch() {
  local url="$1" dest="$2" sum="$3"
  if [[ -f "$dest" ]] && echo "$sum  $dest" | sha256sum -c --status -; then
    echo "    have $(basename "$dest")"
    return
  fi
  echo "    get  $(basename "$dest")"
  curl -fL $([[ -t 2 ]] && echo --progress-bar || echo -sS) -o "$dest.part" "$url"
  echo "$sum  $dest.part" | sha256sum -c --quiet -
  mv "$dest.part" "$dest"
}

echo "==> RKE2 RPMs ($rke2_version, rke2-selinux $rke2_selinux_version)"
# Package locations and checksums from each repository's metadata.
rpm_lookup() {
  python - "$@" <<'EOF'
import gzip, subprocess, sys, xml.etree.ElementTree as ET
base, want = sys.argv[1], sys.argv[2:]   # want: name=version-release
ns = {"r": "http://linux.duke.edu/metadata/repo", "c": "http://linux.duke.edu/metadata/common"}
# curl, not urllib: the repository CDN rejects Python's default client.
get = lambda u: subprocess.run(["curl", "-fsSL", u], check=True, capture_output=True).stdout
repomd = ET.fromstring(get(f"{base}/repodata/repomd.xml"))
href = repomd.find("r:data[@type='primary']/r:location", ns).get("href")
primary = ET.fromstring(gzip.decompress(get(f"{base}/{href}")))
found = {}
for p in primary.findall("c:package", ns):
    name, v = p.find("c:name", ns).text, p.find("c:version", ns)
    key = f"{name}={v.get('ver')}-{v.get('rel')}"
    if key in want:
        cs = p.find("c:checksum", ns)
        assert cs.get("type") == "sha256", cs.get("type")
        found[key] = f"{base}/{p.find('c:location', ns).get('href')} {cs.text}"
missing = [w for w in want if w not in found]
if missing:
    sys.exit(f"not in {base}: {', '.join(missing)}")
print("\n".join(found[w] for w in want))
EOF
}
{
  rpm_lookup "$rke2_repo_base/$rke2_minor/centos/9/x86_64" \
    "rke2-common=$rke2_version-0.el9" "rke2-server=$rke2_version-0.el9"
  rpm_lookup "$rke2_repo_base/common/centos/9/noarch" \
    "rke2-selinux=$rke2_selinux_version"
} | while read -r url sum; do
  fetch "$url" "$OUT/rke2/rpms/$(basename "$url")" "$sum"
done
curl -fsSL -o "$OUT/rke2/rancher-rke2.key" "$(yq_ rke2_gpg_key_url)"

echo "==> RKE2 images ($rke2_tag)"
release="https://github.com/rancher/rke2/releases/download/${rke2_tag/+/%2B}"
curl -fsSL -o "$OUT/rke2/sha256sum-$ARCH.txt" "$release/sha256sum-$ARCH.txt"
for f in "rke2-images-core.linux-$ARCH.tar.zst" "rke2-images-canal.linux-$ARCH.tar.zst"; do
  sum="$(awk -v f="$f" '$2 == f {print $1}' "$OUT/rke2/sha256sum-$ARCH.txt")"
  [[ -n "$sum" ]] || { echo "no checksum for $f" >&2; exit 1; }
  fetch "$release/$f" "$OUT/rke2/images/$f" "$sum"
done

echo "==> Bootstrap: local-path-provisioner"
kubectl kustomize "$REPO_ROOT/gitops/local-path-storage" >"$OUT/bootstrap/local-path-storage.yaml"
mapfile -t images < <(
  grep -oE 'image: *[^ ]+' "$OUT/bootstrap/local-path-storage.yaml" | awk '{print $2}' | sort -u
)
printf '    %s\n' "${images[@]}"
# One OCI archive, all platforms, so each image keeps its upstream index
# digest (the helper image is referenced by digest). containerd names
# imported images from the io.containerd.image.name annotation.
archive="$OUT/bootstrap/local-path-images.tar"
names="$OUT/bootstrap/local-path-images.txt"
if [[ -f "$archive" ]] && [[ "$(cat "$names" 2>/dev/null)" == "$(printf '%s\n' "${images[@]}")" ]]; then
  echo "    have $(basename "$archive")"
else
  layout="$(mktemp -d)"
  trap 'rm -rf "$layout"' EXIT
  declare -A digest_of=()
  for img in "${images[@]}"; do
    d="$(crane digest "$img")"
    [[ "$img" != *@* || "${img#*@}" == "$d" ]] || { echo "digest mismatch for $img" >&2; exit 1; }
    crane pull --format=oci --platform=all "${img%%@*}@$d" "$layout"
    digest_of["$img"]="$d"
  done
  python - <<EOF
import json
path = "$layout/index.json"
pairs = {$(for img in "${images[@]}"; do printf '"%s": "%s", ' "${digest_of[$img]}" "${img%%@*}"; done)}
idx = json.load(open(path))
for m in idx["manifests"]:
    name = pairs[m["digest"]]
    tag = name.rsplit(":", 1)[1] if ":" in name.split("/")[-1] else "latest"
    m.setdefault("annotations", {}).update({
        "io.containerd.image.name": name,
        "org.opencontainers.image.ref.name": tag,
    })
json.dump(idx, open(path, "w"))
EOF
  tar -C "$layout" -cf "$archive.part" .
  mv "$archive.part" "$archive"
  printf '%s\n' "${images[@]}" >"$names"
  echo "    wrote $(basename "$archive")"
fi

echo "==> Zarf $ZARF_VERSION"
zrel="https://github.com/zarf-dev/zarf/releases/download/$ZARF_VERSION"
curl -fsSL -o "$OUT/zarf/checksums.txt" "$zrel/checksums.txt"
for f in "zarf_${ZARF_VERSION}_Linux_$ARCH" "zarf-init-$ARCH-$ZARF_VERSION.tar.zst"; do
  sum="$(awk -v f="$f" '$2 == f {print $1}' "$OUT/zarf/checksums.txt")"
  [[ -n "$sum" ]] || { echo "no checksum for $f" >&2; exit 1; }
  fetch "$zrel/$f" "$OUT/zarf/$f" "$sum"
done
chmod 0755 "$OUT/zarf/zarf_${ZARF_VERSION}_Linux_$ARCH"

echo "==> SHA256SUMS"
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name '*.part' -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
du -sh "$OUT"
