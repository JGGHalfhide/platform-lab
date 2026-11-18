# 0011. etcd snapshots plus Velero to a Garage S3 store on the build host

Status: accepted (Week 7)

## Context

Recovery has to cover the loss of the whole cluster state and the loss of
one application's data, with measured restore times, without any cloud
service. Velero needs an S3-compatible store that survives the cluster.
MinIO, the usual local choice, stopped publishing community builds; Garage
is a single-binary S3 store packaged in the Arch repositories.

## Decision

- Whole cluster: RKE2's scheduled etcd snapshots (every 6 hours, 12 kept)
  plus on-demand snapshots copied to the build host; restore with
  `make etcd-restore` (cluster reset from a snapshot, run via
  `systemd-run` so restored files keep the right SELinux user).
- Application data: Velero with file-system backups (Kopia) to a Garage
  bucket on the build host (`make backup-store`, S3 API on the libvirt
  bridge only).
