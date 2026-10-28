# Praefect role

This role writes `/etc/gitlab/gitlab.rb` for the Praefect service, downloads
the public AWS RDS CA bundle, and runs `gitlab-ctl reconfigure` when the file
changes. It deliberately keeps `praefect['auto_migrate']` disabled. Database
schema migration is a separate manual action on one designated Praefect node.
Set `praefect_refresh_rds_ca_bundle=true` for a planned CA bundle refresh.

Praefect RPC listens without TLS on port 2305 by default. Set
`cluster_rpc_tls_enabled: true` in `group_vars/all` to enable both RPC services
(Gitaly 9999 and Praefect 3305); the TLS certificate
stage must then be completed before configuring Praefect. TLS to the database
is separate and remains enabled with `sslmode: verify-full` by default.

When Praefect RPC TLS is enabled, the TLS certificate role installs the public
internal CA into Ubuntu's system trust store and Praefect verifies its node
certificate against the combined bundle. The CA private key stays on the
bastion. Praefect's outbound database TLS trust bundle is independent of its
RPC listener mode.

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

The role derives Gitaly addresses from the `gitaly` inventory group. For each
node it uses `tcp://` by default on port 8075, or `tls://` on port 9999 when the shared
`cluster_rpc_tls_enabled` switch is true. In TLS mode, the inventory hostname must be in the
node certificate's DNS SAN. The Gitaly storage name defaults to the short
inventory name (for example, `gitaly-1`); the Gitaly role must use the same
storage name.

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

Configure Gitaly nodes first with `playbooks/configure_cluster.yml --tags gitaly`.
For default plaintext Praefect RPC, a node certificate is not required for
Praefect configuration. Ensure the RDS CA bundle URL is reachable from each
Praefect VM. For TLS-enabled Praefect RPC, run the certificates stage first.
Then run:

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

When shared RPC TLS is enabled, the internal CA is installed in
`/etc/gitlab/trusted-certs` and `/usr/local/share/ca-certificates`; the TLS role
runs `update-ca-certificates` to include it in the system bundle. Do not move or
overwrite the system bundle with a single CA certificate. Plaintext RPC does
not require the internal CA. Praefect's separate RDS TLS still uses the AWS RDS
CA bundle.

See [transport instructions](../../TRANSPORT.md) for both modes. The role creates
the parent directory for the RDS CA bundle even when RPC TLS is disabled.
