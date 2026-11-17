# Airgap runbook

How the platform gets onto the disconnected target (`airgap-node-01`, an old
iMac with 8 GB RAM, Rocky Linux 9, single-node RKE2). Everything is built on
the connected build host, carried over as files, and installed with the
target's network egress blocked.

Status: draft. Steps are filled in as they are done; measured results go
in the last section.

## Overview

| # | Where | Step |
|---|---|---|
| 1 | iMac (by hand) | Install Rocky Linux 9 minimal, user `rocky`, lab SSH key |
| 2 | Build host | Stage artifacts: RKE2 RPMs and images, Zarf CLI and init package, Zarf packages |
| 3 | Build host -> iMac | Base and hardening roles; RKE2 from the staged RPMs (no internet needed for RKE2) |
| 4 | iMac | Block egress; prove it with a failing `curl` |
| 5 | iMac | `zarf init`, then `zarf package deploy` for platform, policies, sample app |
| 6 | iMac | Verify: sample app runs, unsigned image rejected, no image pull errors |

Bootstrap order on the target, and why:

1. **RKE2** starts from staged RPMs and its images tarball
   (`/var/lib/rancher/rke2/agent/images/`).
2. **local-path-provisioner** comes up with RKE2 (rendered from
   `gitops/local-path-storage` into RKE2's auto-deploy manifests directory,
   images preloaded the same way). Zarf's registry needs a default
   StorageClass for its PVC, and RKE2 ships none, so this has to exist
   before `zarf init`.
3. **`zarf init`** deploys the Zarf registry (NodePort 31999) and the Zarf
   agent, which rewrites every image reference to `127.0.0.1:31999/...`.
4. **Zarf packages**: platform (Kyverno), policies, sample app.

Argo CD does not run on the target (8 GB RAM; Zarf is the deploy tool there).

## 1. Install Rocky Linux 9 on the iMac (manual, one time)

This is the only manual step. Everything after it is run from the repo.

1. On the build host, download the minimal ISO for the same point release as
   the build node (9.8) and check it against the published checksum:

   ```bash
   curl -LO https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-minimal.iso
   curl -LO https://download.rockylinux.org/pub/rocky/9/isos/x86_64/CHECKSUM
   sha256sum -c CHECKSUM --ignore-missing
   ```

2. Write it to a USB stick (`lsblk` first; the target device is wiped):

   ```bash
   sudo dd if=Rocky-9.8-x86_64-minimal.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

3. Boot the iMac holding the Option (⌥) key and pick **EFI Boot**. If the
   screen goes blank after the boot menu, press `e` on the install entry and
   add `nomodeset` to the kernel line.
4. Use wired Ethernet. The installer has no driver for the iMac's Broadcom
   Wi-Fi.
5. Installer settings:
   - **Software selection:** Minimal Install.
   - **Hostname:** `airgap-node-01`.
   - **Network:** wired interface on, connect automatically. Give it a fixed
     address (a DHCP reservation on the router is simplest) and note it.
   - **Security profile:** none. The `hardening` role applies the STIG
     settings, as on the build node.
   - **Root account:** locked.
   - **User:** `rocky`, administrator (wheel). The installer password is
     temporary; the `hardening` role sets it from Vault.
   - **Installation destination:** custom, LVM, so the STIG partition rules
     pass here (the build VM has one root filesystem and records them as
     exceptions). Sizes for a 500 GB disk; scale to the actual disk:

     | Mount point | Size | Notes |
     |---|---|---|
     | `/boot/efi` | 600 MiB | EFI system partition |
     | `/boot` | 1 GiB | |
     | `/` | 80 GiB | includes `/opt/local-path-provisioner` (PVCs: Zarf registry, sample app database) |
     | `/home` | 10 GiB | |
     | `/tmp` | 5 GiB | |
     | `/var` | rest | containerd images and etcd (`/var/lib/rancher`) |
     | `/var/tmp` | 5 GiB | |
     | `/var/log` | 10 GiB | |
     | `/var/log/audit` | 10 GiB | |
     | swap | none | RKE2/kubelet expects swap off |

6. After the first boot, from the build host, authorize the lab key (ECDSA;
   FIPS mode rejects ed25519) and check the login:

   ```bash
   ssh-copy-id -i ~/.ssh/platform-lab_ecdsa.pub rocky@<imac-ip>
   ssh -i ~/.ssh/platform-lab_ecdsa rocky@<imac-ip> 'cat /etc/rocky-release; free -h; lsblk'
   ```

The iMac keeps internet access until step 4: OS packages for the base and
hardening roles come from the Rocky mirrors. RKE2 and everything on the
cluster come only from staged artifacts.

## 2. Stage the artifacts (build host, connected)

```bash
make airgap-stage      # RKE2 RPMs and images, local-path bootstrap, Zarf CLI and init package
make airgap-packages   # Zarf packages platform, policies, sample-app, signed with the lab cosign key
```

`make airgap-stage` (`scripts/airgap-stage.sh`) writes `build/airgap/`
(about 1.5 GB) and a `SHA256SUMS` over every file:

| Path | Contents | Integrity |
|---|---|---|
| `rke2/rpms/` | `rke2-common`, `rke2-server` 1.36.5~rke2r1, `rke2-selinux` 0.24-1 (the versions on the build node) from rpm.rancher.io | sha256 from the repository metadata; RPM signatures checked on the node against the Rancher key (fingerprint pinned in the rke2 role) |
| `rke2/images/` | `rke2-images-core` and `rke2-images-canal` tarballs | sha256 from the RKE2 release |
| `bootstrap/` | local-path-provisioner rendered from `gitops/local-path-storage`; its two images as one OCI archive (all platforms, so the helper image keeps the digest it is pinned by) | digests checked against the source registry |
| `zarf/` | Zarf CLI and init package v0.89.0 | sha256 from the Zarf release |

`make airgap-packages` (`scripts/airgap-packages.sh`) writes
`build/airgap/packages/`. Package sizes: platform 227 MB, policies 8 KB,
sample-app 963 MB (the sample app images are referenced by their signed
multi-platform index digest, so every platform's layers are included). The
sample app images come from the build cluster's registry together with
their cosign signature (`.sig`) and SBOM attestation (`.att`); `zarf package
create` does not pick those up by itself, so `zarf/sample-app/zarf.yaml`
lists them.

Each package is signed with the lab cosign key (`COSIGN_PASSWORD` from Vault)
and checked against `pki/cosign.pub`; the node checks again on deploy.

Copying by hand instead (USB): copy `build/airgap/` to the node and run
`sha256sum -c SHA256SUMS` in it, and in `packages/`.

## 3. Base, hardening and RKE2 on the node (still connected)

```bash
make inventory AIRGAP_IP=<imac-ip>   # without AIRGAP_IP: the rehearsal VM
make airgap-up                       # site.yml --limit airgap_servers
```

`airgap_servers` (`ansible/group_vars/airgap_servers/`) runs the same
`base`, `hardening`, `openscap` and `rke2` roles as the build node, with
`rke2_airgap: true`:

- RKE2 is installed from the copied RPMs after `rpm --checksig` reports
  `digests signatures OK` for each (dnf does not check local files);
  `container-selinux` comes from Rocky AppStream while still connected.
- RKE2 and bootstrap image archives go to
  `/var/lib/rancher/rke2/agent/images/`; RKE2 imports them at start
  (`Importing images from ...` in `journalctl -u rke2-server`).
- local-path-provisioner goes to `/var/lib/rancher/rke2/server/manifests/`;
  RKE2 applies it, and its namespace is labelled `zarf.dev/agent: ignore`
  so the Zarf agent does not rewrite its helper pods.
- `sample_app_secret` creates the `sample-db` Secret from Vault.

The kubeconfig is saved as `./kubeconfig-airgap`. A second run reports
`changed=0`.

## 4. Block egress

```bash
make airgap-disconnect     # make airgap-reconnect reverses it
```

The `airgap_egress` role installs two firewalld policies on the node:

- `airgap-egress` (HOST to ANY, target REJECT): the node may only open
  connections to its LAN, the pod and service CIDRs, loopback and DHCP
  broadcast. Replies to inbound sessions (SSH, Ansible, kubectl) still flow.
- `airgap-pod-egress` (trusted to public, target REJECT): pods cannot reach
  anything through the external interface.

The play fails unless `curl https://rpm.rancher.io/` fails. Proof on the
rehearsal VM:

```text
$ curl -sS --max-time 8 -o /dev/null https://github.com
curl: (7) Failed to connect to github.com port 443: No route to host
$ dnf makecache --refresh
Error: Failed to download metadata for repo 'baseos': ... Failed to connect to mirrors.rockylinux.org port 443: No route to host
pod egress-test (restricted pod, busybox wget http://1.1.1.1):
wget: can't connect to remote host (1.1.1.1): No route to host
```

## 5. Zarf init and deploy (egress blocked)

```bash
make airgap-deploy     # ansible/airgap-deploy.yml, zarf role
```

On the node, as root, with `KUBECONFIG=/etc/rancher/rke2/rke2.yaml`:

1. Copies the Zarf CLI (`/opt/zarf/zarf`, linked to `/usr/local/bin/zarf`;
   sudo's `secure_path` does not include `/usr/local/bin`, so use the full
   path under sudo), the init package, `pki/cosign.pub` and the packages to
   `/opt/zarf`.
2. `zarf init` from `/opt/zarf`: registry on a 10Gi local-path PVC
   (NodePort 31999), one replica without autoscaling, and the Zarf agent.
3. Creates `kyverno/zarf-registry-pull`: the Zarf pull login (from the
   `zarf-state` Secret) for the registry's Service address, which Kyverno
   uses to check signatures.
4. `zarf package deploy <pkg> --key cosign.pub --verify=always
   --take-ownership` for platform, policies and sample-app, in that order.
   `--verify=always` refuses a package that is unsigned or signed with
   another key. `--take-ownership` lets Helm adopt the objects that exist
   before the release: each namespace's `default` ServiceAccount (declared
   with `automountServiceAccountToken: false`) and the `sample-app` namespace.

A package counts as deployed only when every component in its Zarf record
(`zarf/zarf-package-<name>` Secret) has status `Succeeded` and its aggregate
checksum matches the copied file. Zarf lists a failed deploy at its version
anyway, and a rebuilt package redeploys without a version bump. A second run
reports `changed=0`.

### Policies on the airgapped cluster

`zarf/policies` is `gitops/policies` plus two airgap-only changes:

- `verify-platform-images` points at the Zarf registry. Pods carry
  `127.0.0.1:31999/...` (rewritten by the Zarf agent), while Deployments keep
  `127.0.0.1:30500/...` from Git; both are looked up as
  `zarf-docker-registry.zarf.svc.cluster.local:5000/<repo>@<digest>`, with
  the `zarf-registry-pull` login.
- PolicyExceptions `zarf-platform-images` and `zarf-components-labels`
  (`zarf/policies/exception-zarf-platform.yaml`). Zarf also rewrites the
  upstream images of Kyverno and Zarf itself (by tag, not signed with the lab
  key; their digests are recorded in the signed packages), and Zarf's registry
  and agent charts set no `app.kubernetes.io/name` label. Without the
  exceptions, a restart of the Zarf registry would be rejected at admission
  and the cluster would lose its registry.

## 6. Verify

```bash
make airgap-verify
kubectl --kubeconfig kubeconfig-airgap get events -A | grep -c -E 'ErrImagePull|ImagePullBackOff'   # 0
```

Unsigned image test (`tests/airgap/`): `zarf package create
tests/airgap/unsigned-image` (signed package, unsigned image: Week 4's
`library/busybox:1.36.1`), deploy it on the node like the others, then:

```text
$ kubectl --kubeconfig kubeconfig-airgap apply -f tests/airgap/unsigned-pod.yaml
Error from server: error when creating "tests/airgap/unsigned-pod.yaml": admission webhook
"ivpol.validate.kyverno.svc-fail" denied the request: Policy verify-platform-images failed:
image is not signed with the platform-lab cosign key (pki/cosign.pub); publish it with `make image`
```

The image is in the Zarf registry (the test package's component is
`Succeeded`), so the rejection is for the signature alone. The pod is
otherwise compliant (restricted, labelled, resources set).

## Results

### Rehearsal VM (11/16)

`airgap-rehearsal`: libvirt VM on the build host standing in for the iMac
(8 GiB, 4 vCPU, Rocky 9 GenericCloud, one root filesystem), on the default
NAT network so that step 4 is rehearsed too.

| Step | Result |
|---|---|
| `make airgap-up` (first run) | 7m15s to a Ready node; FIPS on, SELinux enforcing; RKE2 images imported from the staged archives |
| `make airgap-up` (repeat) | `changed=0` |
| `make airgap-disconnect` | host `curl`, `dnf` and pod `wget` all fail: `No route to host` |
| `make airgap-deploy` | init, platform, policies, sample-app deployed with egress blocked; repeat `changed=0` |
| Image pull errors | 0 |
| Sample app images | `127.0.0.1:31999/stefanprodan/podinfo@sha256:fa2f27c1...`, `127.0.0.1:31999/library/postgres@sha256:a77aa70e...`: the digests signed by `make image`, admitted after signature verification |
| Restarts under Enforce | Zarf registry, Zarf agent, a Kyverno controller and the web Deployment all came back |
| Unsigned image | rejected (above) |

Found during the rehearsal and fixed in the repo:

- Zarf's registry needs a default StorageClass before `zarf init`, so
  local-path-provisioner is bootstrapped through RKE2 (step 3).
- `zarf package create` does not include cosign `.sig`/`.att` artifacts by
  itself; `zarf/sample-app/zarf.yaml` lists them.
- Kyverno checks Deployments as written in Git (`127.0.0.1:30500`), not
  only the rewritten pods: the airgap policy maps both prefixes.
- The Zarf agent would rewrite local-path's helper pods to the Zarf registry;
  the namespace is labelled `zarf.dev/agent: ignore`.
- `zarf package deploy --verify always` takes `always` as a second package
  argument; the flag must be `--verify=always`.
- Zarf lists a failed deploy at its version; the role reads component status.

### iMac (11/17)

Hardware: iMac with an Intel Core i5-4570R (x86-64-v2, SSE4.2), 8 GB, 1 TB
disk; Rocky Linux 9.9 minimal from USB, LVM with separate `/`, `/home`,
`/tmp`, `/var`, `/var/tmp`, `/var/log`, `/var/log/audit`.

Differences from the plan, all now in the repo:

- **Network: direct cable to the build host**, not the home LAN. The build
  host shares its Wi-Fi over its second Ethernet port (`eno1`) with
  `make airgap-link-share`: NetworkManager `shared` mode on
  192.168.50.0/24 (DHCP, DNS, NAT), with the iMac's address reserved
  (192.168.50.195). The host's other wired port (`enp3s0`) is a separate
  link and is never touched. On the iMac, the wired profile had to be
  enabled at the console (`nmcli con add type ethernet ... ipv4.method auto`).
- **Bootstrap sudo:** cloud-init gives the VMs passwordless sudo; on the iMac
  the same file was created by hand (`/etc/sudoers.d/90-cloud-init-users`,
  `rocky ALL=(ALL) NOPASSWD:ALL`). The first hardening run deletes it and
  sets the password from Vault.
- **SSH key:** `ssh-copy-id` needs a terminal for the password prompt (run
  it outside Claude Code); host key fingerprint checked at the console first.
- **`python3-libselinux`:** not on a minimal install; added to the base
  role's packages.
- **GRUB:** the iMac boots through the standard Rocky GRUB/BLS setup but has
  no `/etc/default/grub` (written by the installer's bootloader step). The
  hardening role now skips the tasks that edit it and never runs
  `grub2-mkconfig` without it (a rebuilt `grub.cfg` would lose BLS and the
  boot entries' `fips=1`). Kernel arguments still go into the boot entries
  through `grubby`; the GRUB password goes into `/boot/grub2/user.cfg`, which
  the installed `grub.cfg` already reads (superuser stays `root`).
  `grub.cfg` and the EFI partition are unchanged.

| Step | Result |
|---|---|
| `make airgap-up` run 1 | stopped at the missing `/etc/default/grub` after 4m32s (FIPS on, reboot fine; `grub.cfg` untouched) |
| `make airgap-up` run 2 | 9m54s, 52 changes, one reboot (kernel arguments, audit rules); node Ready, 0 image pull errors |
| `make airgap-up` run 3 | 2m18s, `changed=0` |
| Running kernel | `fips=1 ... audit=1 audit_backlog_limit=8192 init_on_free=1 page_poison=1 pti=on vsyscall=none`, SELinux enforcing |

Next on the iMac: egress block (`make airgap-link-cut`, then
`make airgap-disconnect`), then `make airgap-deploy`.
