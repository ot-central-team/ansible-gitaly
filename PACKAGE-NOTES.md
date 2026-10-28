# Complete source package
All 53 tracked files from ot-central-team/ansible-gitaly main at
6deb09c2bd85ed23ca47e148d564e03f4a980764, with shared RPC TLS corrections applied.
Includes the encrypted Vault files exactly as tracked on GitHub. No patch step required.

Rename your old folder as a backup, then extract this archive. Copy across local-only
files and review locally customized inventory/configuration before use. This archive
cannot contain uncommitted changes, ignored eks/local files, local certificates/CA
state, Vault password files or SSH keys from your computer. Preserve existing
CA/server keys; do not regenerate them when replacing source code.
Git history (.git) is not included in this source ZIP.

Set cluster_rpc_tls_enabled: false for both plaintext or true for both TLS in
inventory/lab/group_vars/all/vars.yml. Remove legacy per-service TLS flags from
any local overrides you restore. Database TLS remains separate.
Read README.md and TRANSPORT.md before deployment; NLB and EKS settings must match.
Six local checks passed; no live EC2/RDS/EKS deployment validation was performed.
