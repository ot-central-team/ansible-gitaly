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

Generate the shared token with `openssl rand -hex 32` and store
`praefect_internal_token` as a vaulted variable in
`inventory/lab/group_vars/all.yml`. Store the separate
`praefect_external_token` in `inventory/lab/group_vars/praefect.yml`.

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
