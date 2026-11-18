# Architecture decision records

Each record states one decision and its context.

| # | Decision |
|---|---|
| [0001](0001-rke2-with-cis-profile.md) | RKE2 with the CIS profile as the Kubernetes distribution |
| [0002](0002-rocky-linux-9.md) | Rocky Linux 9 on every node, including the airgapped target |
| [0003](0003-firewalld-stays-on.md) | Keep firewalld on alongside RKE2's Canal CNI |
| [0004](0004-terraform-libvirt-and-ansible.md) | Terraform for VMs, Ansible for everything inside them |
| [0005](0005-argo-cd-app-of-apps.md) | Argo CD with an app-of-apps root for the connected cluster |
| [0006](0006-zot-registry.md) | Zot as the in-cluster registry |
| [0007](0007-supply-chain-signing.md) | SBOM, scan gate and cosign key-pair signatures without a transparency log |
| [0008](0008-kyverno-policy-engine.md) | Kyverno for admission policy and image verification |
| [0009](0009-zarf-airgap-packaging.md) | Zarf for the airgapped deploy; RKE2 from staged RPMs |
| [0010](0010-observability-stack.md) | kube-prometheus-stack, Loki and Alloy for observability |
| [0011](0011-backup-and-restore.md) | etcd snapshots plus Velero to a Garage S3 store on the build host |
