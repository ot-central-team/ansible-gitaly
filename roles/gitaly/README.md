# Gitaly role

This role contains two independently selectable task files:

- `tasks/attach_storage.yml`: format and mount the EBS repository volume.
- `tasks/configuration.yml`: configure the Gitaly service; its RPC listener is
  plaintext by default on port 8075, with TLS available as an explicit opt-in
  on port 9999.

Both use `defaults/main.yml`. The configuration template is in
`templates/gitlab.rb.j2`. The repository filesystem and GitLab package must be
ready before running the configuration tasks. Node TLS certificates are only
required when `cluster_rpc_tls_enabled: true`.

Select the desired task file in your playbook:

```yaml
tasks:
  - name: Configure the Gitaly service
    ansible.builtin.import_role:
      name: gitaly
      tasks_from: configuration.yml
```

Use `tasks_from: attach_storage.yml` to prepare storage instead. Always select
`tasks_from` explicitly; this role has no default `tasks/main.yml` entry point.
The cluster playbook selects these files through its `storage` and `gitaly` stages.

Each Gitaly host needs an explicit `gitaly_storage_name` in `host_vars`. That
name must match the corresponding `storage` entry rendered by the Praefect
role. Praefect selects `tcp://` or `tls://` per Gitaly host from
`cluster_rpc_tls_enabled`.

Required inventory values:

- `praefect_internal_token`: one vaulted shared token used by every Gitaly and
  Praefect node.
- `gitaly_gitlab_secret_token`: when callbacks are enabled, a vaulted token
  shared with the GitLab application's Gitaly/Shell configuration.
- `gitaly_internal_api_url`: when callbacks are enabled, the GitLab
  application's private/internal API URL.
- Per-host `gitaly_storage_name`: `gitaly-1`, `gitaly-2`, and so on.

The role checks that the repository mount exists and, only when TLS is enabled,
that the node certificate/key and CA bundle exist and the certificate verifies.
It writes a root-only `/etc/gitlab/gitlab.rb`, reconfigures only when that file
changes, and disables Rails migrations on the storage nodes.

Outbound HTTPS connections use the persistent service setting
`gitaly['env']['SSL_CERT_FILE']`, pointing to `gitaly_ca_certificate_path`
(default `/etc/ssl/certs/ca-certificates.crt`). When Gitaly RPC TLS is enabled,
this bundle is also used to verify the node certificate. The TLS certificate
role installs the internal CA into Ubuntu's system trust store. This outbound
HTTPS trust setting does not turn on TLS for the Gitaly RPC listener.

Set `cluster_rpc_tls_enabled: true` once in `group_vars/all` to enable TLS
for both Gitaly (9999) and Praefect (3305). With `false`, both use plaintext
(8075 and 2305). Run the complete cluster playbook for a fresh deployment.
Do not override transport per host. See [transport instructions](../../TRANSPORT.md)
for coordinated mode changes, certificate prerequisites and EKS/NLB settings.
The configuration playbook processes one node at a time. Reconfiguration may
restart Gitaly; serial execution alone does not guarantee uninterrupted traffic.
After deployment, check `/opt/gitlab/etc/gitaly/env/SSL_CERT_FILE` on each node
and run `sudo gitlab-ctl praefect check` on Praefect. That check verifies
Praefect-to-Gitaly connectivity; it is not an end-to-end replication test.

Generate the shared token with `openssl rand -hex 32` and store
`praefect_internal_token` as a vaulted variable in
`inventory/lab/group_vars/all/vault.yml`. Store the separate
`praefect_external_token` in `inventory/lab/group_vars/praefect/vault.yml`.

The lab currently sets `gitaly_configure_gitlab_callbacks: false` because its
GitLab application does not exist yet. In this staging state, Gitaly can serve
Praefect requests, but GitLab callback operations such as push authorization
are not ready. When Rails is deployed, set the switch to `true`, configure the
real reachable URL and shared GitLab Shell secret, then rerun the role. The
secret must also be configured on the GitLab application server.

Run after the data disks and GitLab package are ready (and certificates too if
`cluster_rpc_tls_enabled` is enabled). When changing the transport mode, run both the
`gitaly` and `praefect` tags so both ends are updated:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags certificates,gitaly,praefect --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags certificates,gitaly,praefect --ask-vault-pass
```

For the default plaintext mode, omit `certificates` from those commands. Include
it when enabling Gitaly TLS or when you separately need to provision/update
node trust.

Shared package installation lives in `roles/installation` and targets both
Gitaly and Praefect through `playbooks/configure_cluster.yml --tags common,installation`.

## Prepare Gitaly repository disks

On every Gitaly VM, attach the dedicated EBS repository volume using the AWS
attachment name `/dev/sdb`. Keep the root volume on its existing root-device
mapping. Configure the shared convention in `inventory/lab/group_vars/gitaly.yml`:

```yaml
gitaly_data_attachment_name: /dev/sdb
```

No per-host volume ID is required. The role installs `nvme-cli`, reads the AWS
attachment name from each EBS NVMe controller, and requires exactly one match.
Linux may call that disk `/dev/nvme1n1` or a different NVMe number; the AWS
attachment name is what selects it. This workflow requires Nitro/NVMe EBS.
It stops if the attachment is absent/ambiguous, partitioned, layered, read-only,
mounted elsewhere, has unexpected filesystem signatures, or would cover
existing files at the target mountpoint. It does not attach volumes in AWS.

For a confirmed new blank data disk, set `gitaly_format_data_disk: true` in its
host variables. The default is false; existing lab opt-ins are preserved.
Only a disk without a filesystem or detected signatures is formatted. Existing
whole-disk ext4 volumes are reused. The filesystem UUID is still used in fstab
at `/var/opt/gitlab/git-data`. Existing deployments must confirm the attachment
name in AWS before rerunning; the role will not silently choose another disk.

```bash
ansible-playbook playbooks/configure_cluster.yml --tags storage --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags storage --limit gitaly-1.repo-data.internal --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags storage --ask-vault-pass
```

Disk discovery is read-only, including in check mode. On fresh VMs check mode
cannot install missing `nvme-cli` or create a filesystem/UUID, so a complete
fresh-disk dry run is not supported.

When shared RPC TLS is enabled, the internal CA is installed in
`/etc/gitlab/trusted-certs` and `/usr/local/share/ca-certificates`; the TLS role
runs `update-ca-certificates` to include it in the system bundle. Do not move or
overwrite the system bundle with a single CA certificate. The plaintext
Gitaly/Praefect RPC configuration does not require the internal CA.
