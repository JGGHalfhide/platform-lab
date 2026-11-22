# Policy map

How each Kyverno policy in `gitops/policies/` maps to the Kubernetes Pod
Security Standards (PSS), the CIS Kubernetes benchmark that kube-bench runs
(RKE2 CIS 1.9), and the DISA Kubernetes STIG.

Sources:

- DISA Kubernetes STIG **V2R6** (benchmark date 01 Apr 2026, 92 rules),
  `U_Kubernetes_V2R6_STIG.zip` from dl.dod.cyber.mil (SHA-256
  `2e66cc46e19889f337b40a7827745146c40c7b532529c03d826ba7462419876a`). IDs and
  titles below are copied from its XCCDF.
- CIS: control IDs and titles from kube-bench v0.16.0's
  `cfg/rke2-cis-1.9/policies.yaml` (the pinned image `make bench` runs).
  kube-bench reports all of 5.2, 5.5 and 5.7 as **WARN (Manual)**: it cannot
  decide them itself, and these policies are the evidence for them.
- PSS: the control names of the
  [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/).

## How the layers fit

| Layer | What it enforces | Where |
|---|---|---|
| Pod Security admission (built in) | PSS `restricted` on every namespace except `kube-system` and RKE2's own; `local-path-storage` is set to `privileged` for its helper pods | RKE2 CIS profile (`--admission-control-config-file`, STIG V-254800); namespace label in `gitops/local-path-storage/` |
| Kyverno `ValidatingPolicy` (this map) | PSS `restricted` again, plus image, resource and label rules PSS does not cover; produces PolicyReports | `gitops/policies/`, Enforce (`Deny`) since 11/16 |
| Kyverno `ImageValidatingPolicy` | Signatures on platform registry images | `gitops/policies/verify-platform-images.yaml` |

The PSS policies repeat what Pod Security admission already enforces on
purpose: they report on existing workloads (Pod Security admission only
checks new pods), they cover workload controllers at creation time (autogen;
Pod Security admission only warns on Deployments), and they still apply in
`local-path-storage`, whose Pod Security level is `privileged`.

All seven `ValidatingPolicy` resources skip `kube-system` (RKE2-managed;
Kyverno's webhooks skip it anyway).

## Policy to control map

| Policy | Rule | PSS control | CIS (RKE2 1.9) | DISA STIG V2R6 |
|---|---|---|---|---|
| `disallow-privileged-containers` | `securityContext.privileged` unset or false | Privileged Containers (baseline) | 5.2.2 Minimize the admission of privileged containers | V-242437 / CNTR-K8-002010 (intent), V-254800 / CNTR-K8-002011 |
| `disallow-host-path` | no `hostPath` volumes | HostPath Volumes (baseline) | 5.2.12 Minimize the admission of HostPath volumes | V-254800 / CNTR-K8-002011 |
| `pod-security-restricted` | `hostNetwork`, `hostPID`, `hostIPC` unset or false | Host Namespaces (baseline) | 5.2.3, 5.2.4, 5.2.5 host PID, IPC, network namespaces | V-254800 / CNTR-K8-002011 |
| | no `hostPort` | Host Ports (baseline) | 5.2.13 Minimize the admission of containers which use HostPorts | **V-242414 / CNTR-K8-000960** The Kubernetes cluster must use non-privileged host ports for user pods (the policy is stricter: no host ports at all) |
| | Windows `hostProcess` unset or false | HostProcess (baseline) | 5.2.11 Minimize the admission of Windows HostProcess containers | V-254800 / CNTR-K8-002011 |
| | AppArmor `RuntimeDefault` or `Localhost` | AppArmor (baseline) | 5.7.3 Apply SecurityContext to your Pods and Containers | V-254800 / CNTR-K8-002011 |
| | SELinux type a container type; `user` and `role` unset | SELinux (baseline) | 5.7.3 | V-254800 / CNTR-K8-002011 |
| | `procMount: Default` | /proc Mount Type (baseline) | 5.7.3 | V-254800 / CNTR-K8-002011 |
| | only the safe sysctl set | Sysctls (baseline) | 5.7.3 | V-254800 / CNTR-K8-002011 |
| | only configMap, csi, downwardAPI, emptyDir, ephemeral, image, persistentVolumeClaim, projected, secret volumes (`image` as in Kubernetes 1.36's Pod Security admission) | Volume Types (restricted) | 5.7.3 | V-254800 / CNTR-K8-002011 |
| | `allowPrivilegeEscalation: false` in every container | Privilege Escalation (restricted) | 5.2.6 Minimize the admission of containers with allowPrivilegeEscalation | V-242437 / CNTR-K8-002010 (intent), V-254800 / CNTR-K8-002011 |
| | `runAsNonRoot: true` (pod or every container) | Running as Non-root (restricted) | 5.2.7 Minimize the admission of root containers | V-242437 / CNTR-K8-002010 (intent: `MustRunAsNonRoot`), V-254800 / CNTR-K8-002011 |
| | `runAsUser` not 0 | Running as Non-root user (restricted) | 5.2.7 | V-242437 / CNTR-K8-002010 (intent), V-254800 / CNTR-K8-002011 |
| | seccomp `RuntimeDefault` or `Localhost` (pod or every container) | Seccomp (baseline and restricted) | 5.7.2 Ensure that the seccomp profile is set to docker/default in your Pod definitions | V-254800 / CNTR-K8-002011 |
| | drop `ALL`; add only `NET_BIND_SERVICE` | Capabilities (baseline and restricted) | 5.2.8 NET_RAW capability, 5.2.9 added capabilities, 5.2.10 capabilities assigned | V-254800 / CNTR-K8-002011 |
| `disallow-latest-tag` | image (container or image volume) pinned to a tag other than `latest`, or a digest | (none) | 5.5.1 Configure Image Provenance (partly: a known, reviewable image) | No direct rule |
| `restrict-image-registries` | images (containers and image volumes) only from `127.0.0.1:30500/` or `127.0.0.1:31999/` (Zarf) | (none) | 5.5.1 Configure Image Provenance using ImagePolicyWebhook admission controller (met with a Kyverno webhook instead) | No direct rule |
| `verify-platform-images` | platform registry images (containers and image volumes) pinned by digest and signed with `pki/cosign.pub` | (none) | 5.5.1 (same) | No direct rule |
| `disallow-secret-env` | no `env[].valueFrom.secretKeyRef`, no `envFrom[].secretRef` | (none) | (none) | **V-242415 / CNTR-K8-001160** (high) Secrets in Kubernetes must not be stored as environment variables |
| `require-resources` | `requests.cpu`, `requests.memory`, `limits.memory` | (none) | (none) | No direct rule (availability; supports V-242417's separation of workloads by keeping one from starving the node) |
| `require-labels` | `app.kubernetes.io/name` | (none) | (none) | No direct rule (operations: lets reports, dashboards and NetworkPolicies select workloads) |
| All Kyverno policies | enforced through a validating admission webhook | (none) | 5.2.1 Ensure that the cluster has at least one active policy control mechanism in place | V-242436 / CNTR-K8-002000 (intent; the STIG's check only covers the pre-1.25 flag, and the `ValidatingAdmissionWebhook` plugin is on by default in 1.36) |

Notes on the STIG entries:

- **V-242437 (CNTR-K8-002010), "Kubernetes must have a pod security
  policy set".** Its check only describes PodSecurityPolicy, removed in
  Kubernetes 1.25. The requirement behind it (no root, `MustRunAsNonRoot`, no
  privileged pods) is what the PSS controls above enforce. This map marks it
  "intent", not a literal pass.
- **V-254800 (CNTR-K8-002011), "Kubernetes must have a Pod Security Admission
  control file configured".** Met by RKE2's CIS profile (Pod Security admission
  with `restricted` as the default). The Kyverno PSS policies are a second
  layer for the same requirement, not the control the STIG checks.
- **V-242414 (CNTR-K8-000960)** and **V-242415 (CNTR-K8-001160)** are the
  STIG rules policies here meet directly.
- **V-242415** was an open finding until 11/16: Argo CD's upstream manifests
  passed the Redis password as `REDIS_PASSWORD` from a `secretKeyRef` to four
  workloads, and Redis also put it on its command line. Argo CD now reads it
  from the mounted Secret (`REDIS_CREDS_DIR_PATH`) and Redis builds its
  `requirepass` config from the file at startup
  (`gitops/argocd/patches/redis-creds-file.yaml`); `disallow-secret-env`
  keeps it that way.

## Exceptions

PolicyExceptions are enabled only in the `kyverno` namespace (Kyverno
`--exceptionNamespace=kyverno`), which only Argo CD writes to from
`gitops/policies/`.

| Exception | Policies | Scope | Why |
|---|---|---|---|
| `platform-bootstrap-images` | `restrict-image-registries` | Pods in `argocd`, `zot`, `kyverno`, `local-path-storage` | The platform's components start before the in-cluster registry exists (or are the registry), so they run their upstream images. Fine-grained: the policy still runs and only the listed repositories (exact, up to the tag separator) are added to the trusted list. On the airgapped cluster Zarf rewrites every image and this exception matches nothing. |
| `kube-bench-host-access` | `disallow-privileged-containers`, `disallow-host-path`, `pod-security-restricted` | The Job and pods labelled `app.kubernetes.io/name: kube-bench` in `kube-bench` (the namespace exists only while `make bench` runs) | The CIS scanner reads the node's RKE2 configuration: hostPID, read-only hostPath mounts, privileged (`spc_t` under SELinux). Its namespace has the matching Pod Security exemption. The Job sets the label and resources, and its image is pinned by digest. |
| `kube-bench-image` | `restrict-image-registries` | Same | Fine-grained: adds only `docker.io/aquasec/kube-bench@sha256:` (digest references). Found by the Week 5 rebuild: Enforce had blocked `make bench`. |
| `local-path-helper-pods` | `disallow-host-path`, `pod-security-restricted` | Pods named `helper-pod-*` in `local-path-storage` | The helper pods create and delete volume directories on the node: they need a `hostPath` mount and root. The same reason as the namespace's Pod Security exemption. The helper template still meets `require-labels`, `require-resources`, `disallow-latest-tag` and `restrict-image-registries`, and sets seccomp and no privilege escalation. |

## Gaps

Workload-level STIG rules with no policy here yet (candidates for a later
policy):

| STIG | Title | Current state |
|---|---|---|
| V-242383 / CNTR-K8-000290 (high) | User-managed resources must be created in dedicated namespaces. | Not enforced, but met (checked 11/16): `default` holds only `service/kubernetes` (the one allowed object), and `kube-public` and `kube-node-lease` are empty. Also CIS 5.7.4 (The default namespace should not be used). |
| V-242417 / CNTR-K8-001360 (medium) | Kubernetes must separate user functionality. | Not enforced; no user pods run in `kube-system`, `kube-public` or `kube-node-lease`. The policies skip `kube-system`, so a policy for this one would need its own scope. |

Tests for every row above: `make policy-test` (97 cases in
`tests/policies/`). Enforcement evidence: `docs/scans/week5-enforce-test.txt`.
