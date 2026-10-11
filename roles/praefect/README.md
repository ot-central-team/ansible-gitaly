# Praefect role

This role writes `/etc/gitlab/gitlab.rb` for the Praefect service, downloads
the public AWS RDS CA bundle, and runs `gitlab-ctl reconfigure` when the file
changes. It deliberately keeps `praefect['auto_migrate']` disabled. Database
schema migration is a separate manual action on one designated Praefect node.
Set `praefect_refresh_rds_ca_bundle=true` for a planned CA bundle refresh.

The TLS certificate role installs the public internal CA into Ubuntu's system
trust store and runs `update-ca-certificates` when it changes. This lets manual
checks use system trust without shell exports. Praefect also gets a persistent
`SSL_CERT_FILE` service setting pointing to `praefect_gitaly_ca_certificate_path`.
The CA private key stays on the bastion.

To apply this trust setup to existing nodes, run from the Ansible controller:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags certificates --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags praefect --ask-vault-pass
```

The second playbook reconfigures Praefect when its configuration changes and
may restart the service. With a single Praefect node, schedule this for a
maintenance window if serving traffic. Existing database migrations need not
be rerun for this change. On Praefect, verify without shell CA overrides:

```bash
sudo env -u SSL_CERT_FILE -u SSL_CERT_DIR gitlab-ctl praefect check
sudo cat /opt/gitlab/etc/praefect/env/SSL_CERT_FILE
```

The environment file should contain the configured public CA certificate path.

The role derives Gitaly addresses from the `gitaly` inventory group and uses
each inventory hostname as the TLS DNS name. The Gitaly storage name defaults
to the short inventory name (for example, `gitaly-1`); the Gitaly role must use
the same storage name.

## Required secrets

Set two different random values as vaulted inventory variables:

- `praefect_external_token`: used by clients to authenticate to Praefect.
- `praefect_internal_token`: shared by Praefect and all Gitaly nodes; define
  this once in `inventory/lab/group_vars/all/vault.yml` so both groups receive it.

Define `praefect_external_token` in `inventory/lab/group_vars/praefect/vault.yml`.

For example, generate values with `openssl rand -hex 32`, then add them as
Ansible Vault encrypted variables. Do not commit plaintext tokens.

The role reads database connection settings from
`inventory/lab/group_vars/bastion/vars.yml` and the database password from
`inventory/lab/group_vars/bastion/vault.yml`, through the single host in the
`bastion` group.

## Run

Configure Gitaly nodes first with `playbooks/configure_cluster.yml --tags gitaly`. Then issue
and install the Praefect node certificate and ensure the RDS CA bundle URL is
reachable from each Praefect VM. Run:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags praefect --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags praefect --ask-vault-pass
```

After the role succeeds, run the initial schema migration on **one** Praefect
node only (the designated deployment node):

```bash
sudo -u git -- /opt/gitlab/embedded/bin/praefect \
  -config /var/opt/gitlab/praefect/config.toml sql-migrate
```

Verify the migration on that node:

```bash
sudo -u git -- /opt/gitlab/embedded/bin/praefect \
  -config /var/opt/gitlab/praefect/config.toml sql-migrate-status
```

Do not run `sql-migrate` on every Praefect node. For GitLab/Praefect upgrades,
follow the upgrade procedure for the installed GitLab version and continue to
run migrations on only the designated deployment node.
