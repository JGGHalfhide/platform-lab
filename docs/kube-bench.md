# Kubernetes CIS benchmark (kube-bench)

Results of the RKE2 CIS benchmark on the build node (`build-node-01`, RKE2
v1.36.5 with `profile: cis`). Run with `make bench OUT=docs/scans/<name>.txt`.

## How it was measured

- kube-bench v0.16.0 (pinned by digest) as a one-shot Job with
  `--benchmark rke2-cis-1.9`, the newest RKE2 benchmark kube-bench ships
  (the cluster is 1.36). The Job runs with scoped read-only RBAC and an
  explicitly projected token so it does not trip section 5 itself.
- WARN results are Manual checks that kube-bench cannot decide; they are not
  failures.

## Results

| Scan | Workloads on the cluster | Pass | Fail | Warn |
|---|---|---|---|---|
| `week1-kube-bench.txt` | RKE2 system components only | 81 | 0 | 42 |
| `week2-kube-bench.txt` | same, after OS hardening | 81 | 0 | 42 |
| `week3-kube-bench.txt` | plus Argo CD, local-path-provisioner, Zot | 80 | 1 | 42 |
| `week4-kyverno-kube-bench.txt` | plus Kyverno v1.19.2 | 80 | 1 | 42 |

The one Week 3 fail is a documented exception (below). The first Week 3 run,
before fixes, failed 5.1.3, 5.1.5 and 5.1.6.

## Fixes made in Week 3

- **5.1.5 (default service accounts).** The `default` ServiceAccount in
  `argocd`, `local-path-storage` and `zot` is declared in Git with
  `automountServiceAccountToken: false`. RKE2's CIS mode only does this for
  `default`, `kube-public` and `kube-node-lease`.
- **5.1.6 (token mounts).** No ServiceAccount outside `kube-system` automounts
  a token. Workloads that call the API server get an explicitly projected
  token (`kube-api-access` volume: token, `kube-root-ca.crt`, namespace):
  the Argo CD application controller, ApplicationSet controller, dex,
  notifications controller and server; the `secret-init` init container of
  `argocd-redis`; and local-path-provisioner. `argocd-repo-server`, the Redis
  container and Zot get no token at all. See
  `gitops/argocd/patches/token-*.yaml`.

## Kyverno (Week 4)

- No automounted tokens: the chart's `automountServiceAccountToken: false`
  for every component, which makes it mount a projected, time-limited token
  for the four controllers; the namespace `default` ServiceAccount is declared
  in `gitops/kyverno/`.
- The first run after installing failed 5.1.6. The chart's post-upgrade CRD
  migration hook (Argo CD runs it as PostSync) keeps the finished Job's pod
  but deletes its ServiceAccount, and the check treats a pod whose
  ServiceAccount is missing as non-compliant. The pod set
  `automountServiceAccountToken: false` and had exited, so no token was
  exposed. The hook's ClusterRole also uses wildcards (5.1.3) while it runs.
  Fixed by disabling the migration (`crds.migration.enabled: false`): it only
  matters for in-place upgrades, and this cluster upgrades by rebuild.
- No Kyverno ClusterRole uses wildcards.

## Exceptions

| Check | Objects | Reason |
|---|---|---|
| 5.1.3 Minimize wildcard use in Roles and ClusterRoles | ClusterRoles `argocd-application-controller` (`*` on all groups, resources and verbs) and `argocd-server` (`delete`/`get`/`patch` on `*`) | Argo CD is the GitOps controller: it must create and manage any resource type committed to `gitops/`, including CRDs that do not exist yet. Listing resources explicitly would break every sync that adds a new type. Upstream RBAC is kept and the risk is handled by limiting who can change `gitops/` and the Argo CD UI. Rebinding the controller to the built-in `cluster-admin` role would pass the check (kube-bench allow-lists that name) with the same privilege, so it was not done. |

## Pod Security exceptions

The CIS profile enforces the `restricted` Pod Security Standard on every
namespace except `kube-system` and a few RKE2 namespaces.

| Namespace | Enforce | Reason |
|---|---|---|
| `local-path-storage` | `privileged` (warn and audit stay `restricted`) | The provisioner's helper pods create and delete volume directories through a `hostPath` mount, which `baseline` and `restricted` both forbid. The provisioner itself runs with a restricted security context. |

Argo CD, Zot and Kyverno run under `restricted` with no exemption.
