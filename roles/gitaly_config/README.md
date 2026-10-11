# Gitaly configuration role

This role configures the Gitaly service and its TLS listener. It is separate
from `roles/gitaly`, which formats and mounts the EBS repository data volume.
The repository filesystem must already be mounted before this role runs.

Each Gitaly host needs an explicit `gitaly_storage_name` in `host_vars`. That
name must match the corresponding `storage` entry rendered by the Praefect
role. The role uses the inventory hostname as the TLS endpoint name.

Required inventory values:

- `praefect_internal_token`: one vaulted shared token used by every Gitaly and
  Praefect node.
- `gitaly_gitlab_secret_token`: when callbacks are enabled, a vaulted token
  shared with the GitLab application's Gitaly/Shell configuration.
- `gitaly_internal_api_url`: when callbacks are enabled, the GitLab
  application's private/internal API URL.
- Per-host `gitaly_storage_name`: `gitaly-1`, `gitaly-2`, and so on.

The role checks that the repository mount and node TLS files exist, writes a
root-only `/etc/gitlab/gitlab.rb`, and reconfigures only when that file changes.
It disables Rails migrations on the storage nodes.

Outgoing TLS connections use the persistent service setting
`gitaly['env']['SSL_CERT_FILE']`, pointing to `gitaly_ca_certificate_path`
(default `/etc/gitlab/trusted-certs/repo-data-internal-ca.crt`). The role checks
that this public CA file exists before configuring Gitaly. The TLS certificate
role also installs this CA into Ubuntu's system trust store on both Gitaly
and Praefect nodes. No interactive shell export is required.

For existing nodes, run `playbooks/issue_internal_tls.yml` first if the system
trust update has not been applied, then `playbooks/configure_gitaly.yml`.
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

Run after the data disks and TLS certificates are ready:

```bash
ansible-playbook playbooks/configure_gitaly.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_gitaly.yml --ask-vault-pass
```
