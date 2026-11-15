# OS hardening (DISA STIG)

Week 2 result for the build node (`build-node-01`, Rocky Linux 9.8, RKE2
v1.36.5 with the CIS profile). Hardening is done by the `hardening` Ansible
role; scans are run with `make stig-scan`.

## How it was measured

- Scanner: OpenSCAP 1.3.14 with scap-security-guide 0.1.82.
- Content: `ssg-rl9-ds.xml`, profile `xccdf_org.ssgproject.content_profile_stig`.
  DISA publishes the STIG for RHEL 9; this profile is scap-security-guide's
  port of it to Rocky Linux 9, so results are "RHEL 9 STIG as applied to
  Rocky 9", not an official DISA result.
- The scan is not tailored: rules we chose not to fix still count as fails
  and are listed under Exceptions below.
- Reports: `docs/scans/week2-baseline.{html,xml}.gz`,
  `docs/scans/week2-hardened.{html,xml}.gz` (VM hardened in place) and
  `docs/scans/week2-rebuild.{html,xml}.gz` (fresh `make down && make up`;
  identical result, 399 pass / 28 fail).

## Results

| | Baseline (after Week 1) | Hardened | Change |
|---|---|---|---|
| Pass | 164 | 399 | +235 |
| Fail | 261 | 28 | -233 |
| Pass rate (pass / pass+fail) | 38.6% | 93.4% | +54.8 pts |
| High severity fails | 11 | 1 | -10 |
| Medium severity fails | 227 | 22 | -205 |
| Low severity fails | 20 | 5 | -15 |
| Not applicable | 42 | 40 | |
| Not checked (manual) | 10 | 10 | |

All 28 remaining fails are documented exceptions. The one high-severity
fail is `installed_OS_is_vendor_supported`, which Rocky Linux cannot pass.

Kubernetes after hardening: kube-bench (RKE2 CIS 1.9) still reports 81 pass,
0 fail (`docs/scans/week2-kube-bench.txt`), and pod-to-pod, Service, DNS,
egress and NodePort traffic all work with firewalld on.

## What the role changes

Task files in `ansible/roles/hardening/tasks/`:

| File | Covers |
|---|---|
| `admin.yml` | Admin password (Vault), no NOPASSWD sudo, sudo reauthentication, password age on the admin account |
| `fips.yml` | FIPS mode, crypto policy `FIPS:STIG` (SSH ciphers and MACs) |
| `packages.yml` | Required packages (AIDE, USBGuard, fapolicyd, smart card tools, postfix...), removed packages (`nfs-utils`, `rpcbind`, `gssproxy`), kdump/debug-shell/Ctrl-Alt-Del off, local package signature checks |
| `ssh.yml` | sshd settings (no root login, idle timeout, banner, verbose logging...), firewall zone binding |
| `auth.yml` | authselect custom profile with faillock and 100,000 hash rounds, password quality, password aging, umask 077, 10-minute shell timeout, login limits, `su` restricted to wheel |
| `kernel.yml` | 28 sysctls (minus exceptions), 8 unused kernel modules blocked |
| `boot.yml` | Kernel arguments (audit, page poisoning, PTI...), GRUB superuser and password (Vault), `/boot` and `/dev/shm` mount options |
| `audit.yml` | auditd settings, STIG audit rules, immutable rules with panic on audit failure |
| `logging.yml` | rsyslog auth logging, chrony as a client of named servers, hardened chrony-wait unit |
| `aide.yml` | AIDE with SHA-512, ACLs and xattrs, database, daily check mailed to root |

## Exceptions

Rules deliberately left failing. The source of truth is `hardening_exceptions`
in `ansible/roles/hardening/defaults/main.yml`; tasks for these rules are
skipped.

| Rule | Severity | Reason |
|---|---|---|
| `installed_OS_is_vendor_supported` | high | The STIG only recognizes RHEL. Rocky Linux always fails this check. |
| `package_subscription-manager_installed` | medium | Red Hat subscription tooling; not applicable to Rocky Linux. |
| `partition_for_home` | low | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `partition_for_tmp` | low | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `partition_for_var` | low | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `partition_for_var_log` | low | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `partition_for_var_log_audit` | low | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `partition_for_var_tmp` | medium | The Rocky GenericCloud image has a single root filesystem. Separate partitions need a custom disk layout (revisit with an LVM image). |
| `sysctl_net_ipv4_conf_all_forwarding` | medium | Kubernetes nodes route pod and service traffic; forwarding must be on. |
| `sysctl_net_ipv6_conf_all_forwarding` | medium | Kubernetes nodes route pod and service traffic; forwarding must be on. |
| `sysctl_user_max_user_namespaces_no_remediation` | medium | Container runtimes use user namespaces; scap-security-guide ships no remediation for this rule. |
| `service_fapolicyd_enabled` | medium | fapolicyd's deny-by-default policy blocks RKE2 and containerd binaries under /var/lib/rancher. Package installed; trust rules to be designed. |
| `fapolicy_default_deny` | medium | fapolicyd's deny-by-default policy blocks RKE2 and containerd binaries under /var/lib/rancher. Package installed; trust rules to be designed. |
| `banner_etc_issue` | medium | The check requires the DoD notice-and-consent text. This is not a DoD system; a generic authorized-use banner is used instead. |
| `sssd_certificate_verification` | medium | No PKI or smart card (CAC) infrastructure in the lab. |
| `sssd_enable_certmap` | medium | No PKI or smart card (CAC) infrastructure in the lab. |
| `sssd_enable_smartcards` | medium | No PKI or smart card (CAC) infrastructure in the lab. |
| `rsyslog_remote_loghost` | medium | No central log server yet (logging stack is Week 7). |
| `rsyslog_encrypt_offload_actionsendstreamdriverauthmode` | medium | No central log server yet (logging stack is Week 7). |
| `rsyslog_encrypt_offload_actionsendstreamdrivermode` | medium | No central log server yet (logging stack is Week 7). |
| `rsyslog_encrypt_offload_defaultnetstreamdriver` | medium | No central log server yet (logging stack is Week 7). |
| `selinux_context_elevation_for_sudo` | medium | Needs the admin user confined to staff_u; with unconfined_u the sudo role transition fails and locks out automation. Revisit. |
| `accounts_authorized_local_users` | medium | The authorized-user list is site-specific and needs a tailoring file. |
| `network_configure_name_resolution` | medium | The libvirt network provides a single DNS resolver. |
| `fips_custom_stig_sub_policy` | medium | Contradicts harden_sshd_macs_*_crypto_policy in the same profile: this rule wants the sub-policy to list HMAC-SHA2-512 first, the MAC checks want HMAC-SHA2-256 first. Same algorithms, different order; the MAC order is kept so two of the three rules pass. |
| `postfix_client_configure_mail_alias` | medium | The check expects root's alias to be the profile's placeholder value (change_me@localhost). Root's mail goes to the admin user instead. |
| `dir_perms_world_writable_sticky_bits` | medium | Only kubelet pod volumes and container image layers match; Kubernetes manages those paths. |
| `file_permissions_ungroupowned` | medium | Only kubelet pod volumes and container image layers match; Kubernetes manages those paths. |
| `no_files_unowned_by_user` | medium | Only kubelet pod volumes and container image layers match; Kubernetes manages those paths. Files there are owned by container image UIDs (for example 1001, 42, 65532) that have no host account. Appeared in Week 3 once Argo CD and Zot images were on the node. |

## Operational notes

- **Reboots.** FIPS mode, kernel arguments and audit rule changes need a
  reboot. The role reboots once at the end when the running state (not a
  handler) shows one is needed, so a failed run can't lose the reboot.
- **Audit failure mode 2.** The kernel panics if auditing fails, as the STIG
  requires. Watch for `audit: backlog limit exceeded` under heavy load.
- **Account lockout.** Three bad passwords lock an account with no automatic
  unlock (`unlock_time = 0`). If the admin account locks, Ansible can no
  longer use sudo; recovery is a VM rebuild.
- **Password expiry.** The admin password expires after 60 days. Rotate it
  in Vault before then on long-lived nodes, or sudo stops working.
- **SSH keys.** FIPS mode rejects ed25519, so the lab uses an ECDSA P-384 key
  and Ansible only accepts FIPS-approved host key types.
