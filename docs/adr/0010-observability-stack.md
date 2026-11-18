# 0010. kube-prometheus-stack, Loki and Alloy for observability

Status: accepted (Week 7)

## Context

Both clusters need node, etcd and policy metrics, pod logs, and dashboards
in Git, within tight memory (12 GiB build VM, 8 GB target) and under
Pod Security `restricted`. Promtail, the usual Loki agent, is end-of-life.
A log agent that reads files on the node needs `hostPath`, which the
policies forbid outside a few exceptions.

## Decision

kube-prometheus-stack (Prometheus Operator, Prometheus, Grafana,
kube-state-metrics, node-exporter; Alertmanager off), Loki as a single
binary on a filesystem volume, and Alloy collecting pod logs and events
through the Kubernetes API (no `hostPath`). Only node-exporter has host
access, alone in its own namespace with a scoped exception. Dashboards are
JSON in `gitops/monitoring/dashboards/`. Deployed by Argo CD on the build
cluster and by the `zarf/monitoring` package on the target.
