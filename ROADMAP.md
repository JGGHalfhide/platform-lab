# platform-lab Roadmap

Airgapped, STIG-hardened Kubernetes platform. 8 weeks, about 7-10 hours per week.
Status is tracked with the checkboxes below. Claude Code reads this file at the start of each session.

## How to use this file (for Claude Code)

- Read CLAUDE.md and this file at the start of every session.
- Work on the first unchecked item of the earliest incomplete week unless told otherwise.
- Propose changes, show plans (`terraform plan`, `--check`, `--dry-run`) before applying, and ask before anything destructive.
- When a task is done: check its box here, update "Current status" in CLAUDE.md, and commit.
- At the end of a week: confirm every acceptance criterion, tag the repo (`vN.N`), and write down measured results in `docs/`.

## Session templates

Start of session:

```
Read CLAUDE.md and ROADMAP.md. Summarize where we are, then continue with the next unchecked item.
```

End of session:

```
Update ROADMAP.md checkboxes and the "Current status" section in CLAUDE.md. Run terraform fmt/validate and ansible-lint. Show me git status, then commit with a conventional commit message.
```

---

## Week 1 — Foundation

Goal: `make up` builds a Ready, CIS-profile RKE2 cluster from nothing.

- [x] Rocky Linux 9 GenericCloud image in the libvirt pool
  - `scripts/host-bootstrap.sh` (`make host`, run by `make up`): creates the missing `default` pool, uploads the pinned `Rocky-9-GenericCloud-Base-9.8-20260525.0` image after a SHA256 check. Idempotent.
- [x] Terraform: one VM (4 vCPU, 8GB RAM, 40GB disk), COW volume, cloud-init with SSH key, IP output
  - dmacvicar/libvirt `~> 0.9.9`. VM `build-node-01`, user `rocky`, key-only SSH. Outputs `vm_ip`, `ssh_command`.
  - Gotcha: the 0.9 provider starts q35 guests with `acpi=off` unless `features = { acpi = true, apic = {} }` is set; without it the guest never gets a DHCP lease.
- [ ] Prereq: `ansible-core` and `ansible-lint` installed on the build host (not installed as of 10/13)
- [ ] Ansible: inventory generated from Terraform output (generated file is gitignored); base role (updates, chrony, firewall, NetworkManager, SELinux enforcing)
  - Firewall: RKE2 docs say firewalld conflicts with Canal and should be disabled; the STIG requires it on. Decide before writing the role (see Open questions).
  - NetworkManager: drop `/etc/NetworkManager/conf.d/rke2-canal.conf` marking `flannel*`, `cali*`, `tunl*`, `vxlan.calico`, `vxlan-v6.calico`, `wireguard.cali`, `wg-v6.cali` unmanaged (RKE2 known issue).
  - `PermitRootLogin` is `without-password` from the image; set to `no` here or in the Week 2 hardening role.
- [ ] Ansible: RKE2 role (rke2-selinux, `profile: cis`, `etcd` system user, CIS sysctl file, kubeconfig fetched to repo root)
- [ ] kube-bench baseline saved to `docs/scans/week1-kube-bench.txt`
- [ ] Makefile: `up`, `down`, `verify`; full rebuild timed and recorded in README
  - Change `terraform init -upgrade` in `up` to plain `terraform init` so rebuilds use the provider versions locked in `.terraform.lock.hcl`.
- [ ] Tag `v0.1`

Acceptance: `make down && make up` produces `kubectl get nodes` Ready with no manual steps.

Claude Code prompt:

```
Continue Week 1 in ROADMAP.md. Write the Ansible base role and the RKE2 role (CIS profile, SELinux, etcd user, sysctl file). Generate the inventory from the Terraform output. Run with --check first and show me the results before applying. Then run kube-bench with the RKE2 benchmark and save the output to docs/scans/.
```

## Week 2 — OS hardening and compliance baseline

Goal: measurable before/after STIG results on the node OS.

- [ ] Install `openscap-scanner` and `scap-security-guide` on the VM via Ansible
- [ ] Baseline OpenSCAP scan against the STIG profile for the installed datastream (list `/usr/share/xml/scap/ssg/content/` to find it); HTML and XML reports to `docs/scans/week2-baseline.*`
- [ ] Ansible hardening role covering the failed rules (generate remediation with `oscap xccdf generate fix` as a starting point, then convert to idempotent tasks)
- [ ] Re-scan; reports to `docs/scans/week2-hardened.*`
- [ ] `docs/hardening.md`: table of rule IDs, status, and any documented exceptions
- [ ] Confirm RKE2 still starts and passes kube-bench after hardening
- [ ] Tag `v0.2`; publish Post 1 (hardening results)

Acceptance: second scan shows a measurable pass-rate increase; `make up` still works end to end.

Claude Code prompt:

```
Week 2 in ROADMAP.md. Add OpenSCAP scanning to the Ansible roles, run the baseline STIG scan against the Rocky VM, and save the HTML/XML reports to docs/scans/. Then build an idempotent hardening role for the failed rules, with a variable-driven exceptions list for rules that break RKE2. Re-scan and produce docs/hardening.md with before/after pass counts.
```

## Week 3 — GitOps and registry

Goal: cluster state is driven from `gitops/`.

- [ ] Install Argo CD (Helm or manifests) via an Ansible task or Makefile target, once
- [ ] App-of-apps root application pointing at `gitops/apps/`
- [ ] Argo CD manages itself from Git
- [ ] In-cluster registry (Zot by default; Harbor optional) deployed via Argo CD, with persistent storage (local-path-provisioner)
- [ ] Ingress using the controller bundled with the installed RKE2 version (check `kubectl get pods -n kube-system`)
- [ ] Push a test image to the registry and pull it from a pod
- [ ] Tag `v0.3`

Acceptance: deleting an app's resources causes Argo CD to restore them; a commit to `gitops/` changes the cluster.

Claude Code prompt:

```
Week 3 in ROADMAP.md. Install Argo CD, create the app-of-apps layout under gitops/, and have Argo CD manage itself. Deploy an in-cluster OCI registry through Argo CD with persistent storage. Show me the manifests before committing, and verify by pushing and pulling a test image.
```

## Week 4 — Supply chain

Goal: every platform image is scanned, has an SBOM, and is signed; unsigned images are rejected.

- [ ] Script/Makefile target: pull image, generate SBOM (Syft), scan (Trivy), push to in-cluster registry
- [ ] cosign key pair generated locally (private key never committed; public key committed under `gitops/` or `docs/`)
- [ ] Sign images and attach SBOM attestations with cosign
- [ ] Optional: GitHub Actions workflow for the connected build path (scan + SBOM on push)
- [ ] Kyverno installed via Argo CD
- [ ] Kyverno `verifyImages` policy using the cosign public key
- [ ] Test: signed image admitted, unsigned image rejected (record both outputs in `docs/`)
- [ ] Tag `v0.4`; publish Post 2 (supply chain)

Acceptance: an unsigned image deployment fails admission with a clear policy message.

Claude Code prompt:

```
Week 4 in ROADMAP.md. Build a script that pulls an image, runs Syft and Trivy, pushes it to the in-cluster registry, and signs it with cosign using a local key pair (add the private key path to .gitignore). Install Kyverno through Argo CD and add a verifyImages policy using the public key. Prove it with one signed and one unsigned deployment and save the outputs under docs/.
```

## Week 5 — Policy set

Goal: documented policies mapped to Pod Security Standards and Kubernetes STIG findings.

- [ ] Policies under `gitops/policies/`: Pod Security Standards restricted equivalents, no `latest` tags, required resource requests/limits, no privileged containers, no hostPath, required labels, trusted registries only
- [ ] `kyverno test` cases for each policy, run via a Makefile target
- [ ] All policies in Audit mode first; review PolicyReports; fix or exempt findings
- [ ] Switch to Enforce
- [ ] `docs/policy-map.md`: policy → control/finding mapping
- [ ] Tag `v0.5`

Acceptance: `make policy-test` passes; a deliberately non-compliant pod is rejected with a readable message.

Claude Code prompt:

```
Week 5 in ROADMAP.md. Write the Kyverno policy set under gitops/policies/ with kyverno test cases and a make policy-test target. Deploy in Audit mode through Argo CD, show me the PolicyReport results, then prepare the switch to Enforce. Create docs/policy-map.md mapping each policy to Pod Security Standards and the Kubernetes STIG.
```

## Week 6 — Airgap deployment

Goal: the same platform runs on the iMac cluster with no internet access.

- [ ] iMac: Fedora prepared, hardening role applied (adjust inventory), single-node RKE2 installed from airgap artifacts (RKE2 images tarball + install script staged over scp)
- [ ] Zarf installed on the build host (`zarf version` recorded)
- [ ] Zarf package definitions under `zarf/` for: platform components, Kyverno policies, sample app
- [ ] `zarf package create` on the connected host; transfer the package file to the iMac via scp/USB
- [ ] Disconnect: firewall rule blocking egress on the iMac; prove with a failing `curl`
- [ ] `zarf init` and `zarf package deploy` on the iMac with the network blocked
- [ ] Sample app runs; unsigned image still rejected by policy
- [ ] `docs/airgap-runbook.md`: exact step list
- [ ] Tag `v0.6`; publish Post 3 (airgap deploy)

Acceptance: platform and sample app come up on the iMac with egress blocked and no image pull errors.

Claude Code prompt:

```
Week 6 in ROADMAP.md. Prepare the iMac as a second RKE2 node set (single node) using our Ansible roles with a separate inventory group. Create Zarf package definitions under zarf/ for the platform, policies, and sample app. Document each step as you go in docs/airgap-runbook.md. Stop and ask me before blocking network egress on the iMac.
```

## Week 7 — Observability and recovery

Goal: metrics, logs, and a measured restore.

- [ ] kube-prometheus-stack and Loki (with Alloy; Promtail is end-of-life) deployed via Argo CD; included in the Zarf package
- [ ] Grafana dashboards for node, etcd, and policy reports committed as JSON under `gitops/`
- [ ] etcd snapshot: scheduled snapshots configured, manual `rke2 etcd-snapshot save`
- [ ] Restore drill: destroy state, `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`, verify; record elapsed time
- [ ] Velero with an in-cluster or local S3-compatible backend (MinIO); back up and restore the sample app namespace; record elapsed time
- [ ] `docs/recovery.md` with RTO measurements and procedures
- [ ] Tag `v0.7`

Acceptance: both restore drills complete with recorded times; dashboards show data on both clusters.

Claude Code prompt:

```
Week 7 in ROADMAP.md. Deploy kube-prometheus-stack and Loki through Argo CD, commit the Grafana dashboards as JSON, and add them to the Zarf package. Then walk me through the etcd snapshot restore drill and the Velero backup/restore drill, timing each, and write the procedures and measured times into docs/recovery.md. Ask before any step that destroys cluster state.
```

## Week 8 — Polish and publish

Goal: a repo a stranger can read and reproduce.

- [ ] README: overview, architecture diagram (Mermaid), quickstart, repo layout, measured results table
- [ ] ADRs in `docs/adr/` for the main platform choices (state the decision and context only)
- [ ] Demo recording (asciinema or screen capture) of `make up` through a policy rejection
- [ ] Secret scan with gitleaks over full history; fix anything found
- [ ] LICENSE (MIT or Apache-2.0)
- [ ] Confirm no employer-derived names, configs, or hostnames anywhere in the repo
- [ ] CI: terraform fmt/validate, ansible-lint, yamllint on pull requests
- [ ] Tag `v1.0`; publish Post 4 (architecture and lessons)

Acceptance: a fresh clone plus the README quickstart reproduces the build cluster.

Claude Code prompt:

```
Week 8 in ROADMAP.md. Write the README with a Mermaid architecture diagram and a results table pulled from docs/. Generate ADRs for the main platform choices. Run gitleaks over the full git history and report findings. Add a CI workflow for fmt/validate/lint. Then do a final pass to confirm nothing in the repo references any employer system.
```

---

## Open questions

Decide these before the week that depends on them.

- **Firewall vs. Canal (Week 1).** Options: (a) keep firewalld on with RKE2 ports open and the CNI interfaces and pod/service CIDRs in the `trusted` zone, verified with pod-to-pod and DNS tests; or (b) disable firewalld per RKE2 docs and record a STIG exception with an ADR. (a) keeps the STIG control and is the more useful result if it holds up under testing.
- **iMac OS (Week 6).** Fedora has no STIG profile in scap-security-guide (CIS, OSPP, PCI-DSS and others only), and rke2-selinux packages target EL. Running Rocky 9 on the iMac too would let the same hardening role and STIG scan apply to both clusters.
- **iMac memory (Week 6-7).** 8 GB is tight for RKE2 plus Argo CD, Kyverno, a registry, Prometheus and Loki. Expect to trim (for example, no Argo CD on the target, since Zarf deploys) or set small resource limits.
- **Zarf and Kyverno image verification (Week 6).** Zarf rewrites image references to its own in-cluster registry. Test early that the `verifyImages` policy still admits signed images after the rewrite.

---

## After Week 8 — Phase 2 and 3 skeletons

### Phase 2: Local LLM inference on the platform

- [ ] Choose a small quantized model; serve with vLLM or llama.cpp in a pod
- [ ] Package model and runtime for the airgapped cluster via Zarf
- [ ] KEDA autoscaling on request queue depth
- [ ] OpenTelemetry and Prometheus metrics: latency, tokens per second, queue depth
- [ ] Load test; document cost and latency per million tokens (CPU, then a short rented GPU run)
- [ ] Post: inference platform results

### Phase 3: Reliability layer

- [ ] SLO definitions and burn-rate alerts for the sample app and the inference service
- [ ] Chaos Mesh or Litmus experiments with a postmortem per experiment under `docs/postmortems/`
- [ ] LLM triage agent: retrieval over runbooks and postmortems, with a small evaluation set and recorded accuracy
- [ ] Post: SRE layer results

---

## Ground rules

- Built from scratch on personal hardware.
- No configs, naming, hostnames, or architecture from any employer system appear in code, docs, or posts.
- Secrets, kubeconfigs, key files, and state files are never committed.
- Sample applications are generic (a small web app and a database).

