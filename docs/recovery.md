# Recovery

Backups and restores for the build cluster, with measured times: an etcd
snapshot restore of the whole cluster (RTO 2 min 51 s) and a Velero restore
of one namespace (RTO 22 s).

## etcd snapshots

RKE2 takes scheduled snapshots (rke2 role, `rke2_config`):

| Setting | Value |
|---|---|
| `etcd-snapshot-schedule-cron` | `0 */6 * * *` (every 6 hours) |
| `etcd-snapshot-retention` | 12 (3 days) |
| `etcd-snapshot-compress` | true |
| Location on the node | `/var/lib/rancher/rke2/server/db/snapshots` |

On demand, with a copy kept off the node:

```bash
make etcd-snapshot SNAPSHOT=<name>     # LIMIT=airgap_servers for the airgapped node
make etcd-snapshots                    # list what RKE2 knows about
```

The copy lands in `build/etcd-snapshots/<host>/` on the build host (0700
directory, 0600 file). First snapshot: `week7-baseline`, 4.3 MB compressed
(11/16). RKE2's CIS profile encrypts Secrets at rest, so the snapshot holds
them encrypted.

### Drill: restore the whole cluster from a snapshot (11/17, build cluster)

Point in time: ConfigMap `drill-before` created, snapshot
`pre-restore-drill-build-node-01-1794950188.zip` taken (5.3 MB, copied to
the build host), then ConfigMap `drill-after` created. A correct restore
brings back `drill-before` and not `drill-after`.

Timeline (UTC):

| Time | Step |
|---|---|
| 21:16:57 | `systemctl stop rke2-server`, `rke2-killall.sh`; etcd data directory moved aside (state destroyed) |
| 21:17:03 | `rke2 server --cluster-reset --cluster-reset-restore-path=...`: snapshot restored (6 s) |
| 21:17-21:27 | the reset waited for etcd, which failed with `open .../db/etcd/config: permission denied` |
| ~21:37 | cause found and fixed (below); `rke2-server` started |
| 21:38:27 | node Ready |
| 21:38:39 | all 11 Argo CD apps Synced/Healthy |
| 21:44:20 | `db-0` Ready after deleting its stuck pod (below) |

Result: `drill-before` present, `drill-after` absent (restored to the
snapshot); sample database identical (`1000|8e64511e...`); policy reports
514 pass / 0 fail; kube-bench 80 pass / 1 fail, unchanged
(`docs/scans/week7-etcd-restore-kube-bench.txt`).

**Measured outage: 21m42s** to all apps healthy, 27m23s to the database pod,
almost all of it the detour below. The second run (playbook, below) measured
the procedure itself: 2 min 51 s.

What went wrong in the first run (all now handled by the playbook):

1. **SELinux user on restored files.** The reset ran from an interactive
   root shell (Ansible `sudo`), so the files it wrote got the SELinux user
   `unconfined_u` instead of `system_u`. Owner, mode and type matched
   (`etcd:etcd 0600`, `rke2_service_db_file_t`), yet etcd was refused and
   nothing reached the audit log. `restorecon -R -F` on `server/db` fixed it.
   Run the reset through `systemd-run` (as the service runs) or relabel
   before starting.
2. **Stuck pods.** `rke2-killall.sh` removes every container; the restored
   Pod objects still describe the old ones. Most pods recovered on their
   own; the StatefulSet pod `db-0` stayed Pending with no events. Deleting
   the pod (not its PVC) let the StatefulSet recreate it; the volume and its
   data are not in etcd and were untouched.
3. **One reset is enough.** The first reset had already reset the
   membership; a second one stops with "membership was previously reset".

### Second run: the playbook (11/17)

`make etcd-restore SNAPSHOT=<name> CONFIRM=yes` (`ansible/etcd-restore.yml`)
builds in everything the first run taught: snapshot copied out of
`server/db`, `server/db` never moved, reset through `systemd-run`,
`restorecon -RF`, stuck pods recreated after a 60 s grace period (never
their PVCs), and its own timing. Same marker test (`drill2-before`,
snapshot `drill2`, `drill2-after`):

| Measure (from stopping rke2-server) | Time |
|---|---|
| Node Ready | 105 s |
| All pods running | 166 s |
| All Argo CD apps Synced/Healthy and `db-0` Ready | 171 s |

Result: `drill2-before` present, `drill2-after` absent; sample database
identical; 0 pods not running; snapshots `drill2` and `post-drill` still on
the node afterwards. No manual step.

**Measured RTO, full etcd restore of the build cluster: 2 min 51 s.**

### Procedure

```bash
make etcd-snapshots                                   # pick a snapshot
make etcd-restore SNAPSHOT=<name> CONFIRM=yes         # LIMIT=airgap_servers for the iMac
```

Everything written to etcd after the snapshot is lost; volume data on disk
is not in etcd and is kept. The playbook refuses to run without both
`SNAPSHOT` and `CONFIRM=yes`.

**Never move or delete `server/db` by hand.** It holds `snapshots/` too:
after the first drill, deleting the moved-aside pre-drill directory also
deleted the node's scheduled snapshots of that day (the two manual ones
survived as copies on the build host, `build/etcd-snapshots/`). The reset
only replaces `server/db/etcd`.

## Velero

### Components

- **Backup store:** Garage 2.5.0 on the build host (`make backup-store`,
  `scripts/backup-store.sh`): Arch package, single node, S3 API only on the
  libvirt bridge (`192.168.122.1:3900`), RPC and admin on localhost, data in
  `/var/lib/garage`. Bucket `velero`, one read/write key. Backups survive the
  loss of the cluster. Nothing leaves the host.
- **Velero:** chart 12.2.2, Velero v1.18.4, AWS plugin v1.14.4, through Argo
  CD (`gitops/apps/velero.yaml`, values in `gitops/values/velero.yaml`).
- **Secrets** (`velero_secrets` role, from Vault): `velero-s3` (credentials
  file, mounted) and `velero-repo-credentials` (the Kopia repository
  password that encrypts file-system backups; Velero's built-in default
  would be the same in every install).
- **Volumes:** file-system backup with Kopia. local-path has no CSI
  snapshots, and Velero skips `hostPath` volumes, so the StorageClass
  creates `local` volumes (`defaultVolumeType: local`).

### Hardening and exceptions

| Piece | How it runs | Exception |
|---|---|---|
| Velero server | restricted: non-root, read-only root, no capabilities, projected token | none |
| Node agent | root, hostPath `/var/lib/kubelet/pods`, SELinux `spc_t`, read-only root, file capabilities only | PSS `privileged` on `velero` (warn/audit restricted); PolicyException `velero-node-agent` |
| Per-volume hosting pods (Velero 1.18) | root, hostPath, **privileged** (`privilegedFsBackup`) | PolicyExceptions `velero-node-agent` and `velero-hosting-pods-privileged`, matched by Velero's `velero.io/pod-volume-backup`/`-restore` label in `velero` only |
| Restore helper (init container in restored pods) | signed Velero image from the platform registry, pinned by digest, restricted (`gitops/velero/restore-helper-config.yaml`) | none |
| ServiceAccount | bound to `cluster-admin` (chart default; backup and restore of arbitrary resources) | kube-bench allow-lists `cluster-admin` |

Why privileged hosting pods: with SELinux enforcing, the kubelet relabels
each pod's volume with that pod's own MCS categories
(`container_file_t:s0:c128,c602`). A hosting pod (`container_t`, other
categories) is refused; the container policy does not audit these denials,
so they show up only as `permission denied` in the PodVolumeBackup. Privileged
pods run as `spc_t`. The same relabelling broke local-path's delete helper
after the switch to `local` volumes; it now runs with `spc_t` (not
privileged).

Read-only root filesystems need writable `/tmp` (node agent), `/udmrepo`
(Kopia config) and `/.cache` (Kopia cache) as emptyDirs.

### Drill: sample app namespace (11/16, build cluster)

| Step | Result |
|---|---|
| Test data | 1000 rows in `sample.drill`, `count|md5` = `1000|8e64511e4a47b91be2c79c929dbd73d2` |
| Backup `sample-app-drill-5` | Completed in **20 s**; 79 items; volumes: db `data` 48.6 MB, `run`, `tmp`, web `data` |
| Delete | Argo CD automated sync paused (`root`, `sample-app`); namespace deleted (139 s including volume teardown) |
| Restore `sample-app-drill-5-restore` | Completed; **22 s** from creating the Restore to `db-0` Ready; 23 items; 1 warning (emptyDir volumes have no PVC) |
| Verify | `1000|8e64511e4a47b91be2c79c929dbd73d2` (identical); `sample-db` Secret restored; web `/readyz` 200; restore helper ran the signed image; policy reports 37 pass / 0 fail |
| Argo CD | sync re-enabled (`kubectl apply --server-side -f gitops/root.yaml`); `sample-app` Synced/Healthy, restored objects adopted, data kept |

**RTO, sample app namespace: 22 s** (restore to database Ready), plus the
time to pause and re-enable Argo CD.

### Procedure

```bash
K="kubectl --kubeconfig kubeconfig"
# Backup
cat <<YAML | $K apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata: {name: <name>, namespace: velero}
spec:
  includedNamespaces: [sample-app]
  defaultVolumesToFsBackup: true
  ttl: 720h0m0s
YAML
$K -n velero get backup <name> -o jsonpath='{.status.phase}'      # Completed

# Restore: pause Argo CD first, or it recreates an empty app
for a in root sample-app; do
  $K -n argocd patch application $a --type json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
done
cat <<YAML | $K apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata: {name: <name>-restore, namespace: velero}
spec:
  backupName: <name>
  includedNamespaces: [sample-app]
YAML
$K -n velero get restore <name>-restore -o jsonpath='{.status.phase}'   # Completed
$K apply --server-side -f gitops/root.yaml        # re-enables sync for everything
```

Delete a backup (and its data in the bucket) with a `DeleteBackupRequest`,
not by deleting the Backup object.
