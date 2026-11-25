# Observability

Metrics, logs and dashboards for the build cluster (Week 7). The same chart
values are meant for the airgapped cluster's Zarf package.

## Components

| Component | Chart / version | Namespace | Notes |
|---|---|---|---|
| Prometheus Operator, Prometheus | kube-prometheus-stack 92.17.0 (operator v0.94.2, Prometheus v3.15.1) | `monitoring` | 3 days / 6 GB retention on an 8 Gi local-path volume |
| Grafana | (subchart) 13.3.0 distroless | `monitoring` | datasources and dashboards from Git; no persistence |
| kube-state-metrics | (subchart) v2.20.0 | `monitoring` | also exports Kyverno PolicyReport summaries |
| node-exporter | (subchart) v1.12.1 | `monitoring-node` | the only pod with host access |
| Loki | loki 7.5.0 (Loki 3.6.11) | `monitoring` | single binary, filesystem on a 5 Gi local-path volume, 7 days |
| Alloy | alloy 1.15.0 (Alloy v1.21.3) | `monitoring` | pod logs and Kubernetes events through the API |
| Tempo | grafana-community/tempo 3.2.1 (Tempo 3.1.1) | `monitoring` | traces for local-agents (its ADR 0008: metadata only); single binary, OTLP/HTTP :4318, filesystem on a 2 Gi local-path volume, 7 days; Grafana datasource; 29 MiB idle, 152 MiB after one agent run (local-agents docs/scans/week4-tracing.txt) |

All through Argo CD (`gitops/apps/kube-prometheus-stack.yaml`, `loki.yaml`,
`alloy.yaml`, `tempo.yaml`), values in `gitops/values/`. Off: Alertmanager (no receiver
yet), the operator's admission webhooks and their certificate Jobs, Grafana's
test pod and default dashboards, Loki's caches, gateway, canary and
self-monitoring.

## Hardening

- **Pod Security:** everything in `monitoring` runs restricted. node-exporter
  is alone in `monitoring-node` (enforce `privileged`, warn/audit
  `restricted`) with host network, host PID, read-only `/proc`, `/sys`, `/`,
  and the `spc_t` SELinux type: `container_t` cannot read the host's
  `/proc/1/mountinfo` (init_t), which the filesystem collector needs. It is
  not privileged and runs as non-root with no capabilities. Kyverno:
  PolicyException `node-exporter`.
- **Logs without host access:** Alloy reads logs through the API
  (`loki.source.kubernetes`), not from `/var/log/pods`, so it needs no
  hostPath, root or SELinux exception.
- **Tokens (CIS 5.1.5/5.1.6):** no automounted tokens; the operator,
  Prometheus, kube-state-metrics, Grafana's dashboard sidecar and Alloy get a
  projected, time-limited one. Loki and node-exporter get none.
- **No Secrets in env (STIG V-242415):** Grafana's admin login is the
  `grafana-admin` Secret (from Vault, `grafana_admin` role), mounted and read
  with Grafana's `$__file{}` expansion (the distroless image has no
  `/run.sh` for `__FILE` variables). The dashboard sidecar runs without
  reload calls and the datasource sidecar is off, since both would put the
  login in their environment.
- **Images:** upstream, by exact repository, in `monitoring` and
  `monitoring-node` only (`platform-bootstrap-images`).
- **inotify limits (fixed 11/22):** from 11/18 the node ran out of inotify
  instances (kernel default 128 per user; root held 127: kubelet, API
  server, controllers, containerd). The kubelet then wrote `failed to create
  fsnotify watcher: too many open files` into followed log streams, about
  1,000-1,600 lines an hour in Loki across every namespace. The base role
  now sets `fs.inotify.max_user_instances=8192` and
  `fs.inotify.max_user_watches=524288` (`base_sysctls`,
  `/etc/sysctl.d/90-kubernetes-node.conf`; tag `sysctl` to apply alone).

## Scrape targets

| Target | How |
|---|---|
| API server, kubelet, cAdvisor | kube-prometheus-stack defaults |
| etcd | RKE2 `etcd-expose-metrics: true` (rke2 role): `:2381`, plain HTTP. firewalld does not open 2381 in the public zone, so only the node and pods (trusted zone) reach it; blocked from the build host |
| CoreDNS | `:9153`; NetworkPolicy `allow-prometheus-coredns-metrics` in `kube-system`, because RKE2's CIS NetworkPolicies admit only DNS from other namespaces |
| node-exporter, kube-state-metrics, Grafana, the operator, Prometheus, Loki | ServiceMonitors |
| Not scraped | controller manager, scheduler, kube-proxy: RKE2 binds their metrics to 127.0.0.1 (CIS 1.3.7, 1.4.2) |

All 13 targets up (11/17).

## Dashboards

JSON in `gitops/monitoring/dashboards/`, loaded as ConfigMaps (label
`grafana_dashboard`) into the Grafana folder `platform-lab`:

| Dashboard | UID | Shows |
|---|---|---|
| Node | `platform-node` | CPU, memory, pressure (PSI), load, every filesystem (the iMac's separate STIG partitions each get a line), network, disk |
| etcd | `platform-etcd` | leader, leader changes, WAL fsync and backend commit p99, database size vs in use, proposals, keys, client traffic |
| Policy reports | `platform-policy-reports` | pass/fail/warn/error/skip totals, failures by namespace, results over time |

Policy report metrics come from kube-state-metrics' custom resource state
(`kyverno_policyreport_summary{namespace,name,result}` and
`kyverno_clusterpolicyreport_summary`), which reads the `summary` of each
`wgpolicyk8s.io/v1alpha2` report. First reading: 518 pass, 0 fail,
8 skip (the scoped PolicyExceptions).

Opening Grafana: `kubectl --kubeconfig kubeconfig -n monitoring port-forward
svc/kps-grafana 3000:80`; the login is in the `grafana-admin` Secret
(user `platform-admin`).

## Results (11/17, build cluster)

| Check | Result |
|---|---|
| Argo CD | three apps Synced/Healthy 80 s after the push |
| Loki | logs from all 9 namespaces |
| kube-bench | 80 pass / 1 fail (5.1.3, Argo CD; unchanged), `docs/scans/week7-monitoring-kube-bench.txt` |
| Memory | node 7.3 GiB of 11.7 GiB in use; Grafana ~350 MiB, Prometheus ~330 MiB, Alloy, Loki, kube-state-metrics ~90 MiB each |

## Airgapped cluster (the iMac)

Same charts, values, namespaces, dashboards and CoreDNS NetworkPolicy,
packaged as `zarf/monitoring` (0.7.0, 976 MB, signed) and deployed with
`make airgap-deploy` with egress blocked. Grafana: `kubectl --kubeconfig
kubeconfig-airgap -n monitoring port-forward svc/kps-grafana 3001:80` from
the build host (over the direct link), same login.

Differences from the build cluster:

- **Images** come from the Zarf registry (rewritten by the Zarf agent).
  They are upstream images, not signed with the lab key, so the airgap
  policy exception `zarf-platform-images` (zarf/policies) covers
  `monitoring` and `monitoring-node` as it does `zarf` and `kyverno`.
- **Namespace labels:** Zarf resets the labels of every namespace a chart
  deploys into to its own set (`app.kubernetes.io/managed-by: zarf`,
  `zarf.dev/agent: mutate`), which drops `monitoring-node`'s Pod Security
  exemption; node-exporter's pods were then rejected as
  `restricted:latest` and the Helm install timed out (twice). The package
  installs kube-prometheus-stack without a Helm wait, then re-labels the
  namespace, restarts the node-exporter DaemonSet (the controller backs off
  ~16 minutes after repeated rejections) and waits for node-exporter,
  Prometheus and Grafana. A redeploy that strips the labels again restores
  them the same way.
- **etcd metrics and the Grafana login** are applied by `make airgap-up`
  (rke2 and grafana_admin roles), which now runs offline: the airgap group
  skips the package update (`base_update_packages: false`).

### Results (11/17, iMac)

| Check | Result |
|---|---|
| Scrape targets | 13/13 up (API server, kubelet, etcd, CoreDNS, node-exporter, kube-state-metrics, Loki, Grafana, operator, Prometheus) |
| Policy reports | 295 pass, 0 fail, 44 skip |
| Filesystems | each STIG partition: `/`, `/home`, `/tmp`, `/var`, `/var/tmp`, `/var/log`, `/var/log/audit`, `/boot`, `/boot/efi` |
| Loki | logs from all 7 namespaces |
| Grafana | the three dashboards in `platform-lab` |
| Memory before the stack | 3.7 GiB of 7.4 GiB in use, requests 42% |

Dashboards show data on both clusters (Week 7 acceptance).
