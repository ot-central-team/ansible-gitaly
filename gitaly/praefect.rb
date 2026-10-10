# Reference configuration for the current lab inventory. The Ansible role
# renders the live /etc/gitlab/gitlab.rb from inventory and vaulted variables.
# The current lab has two Gitaly hosts, so replication factor is 2. For the
# recommended production topology, add a third Gitaly host and use factor 3.

gitaly['enable'] = false
postgresql['enable'] = false
redis['enable'] = false
nginx['enable'] = false
puma['enable'] = false
sidekiq['enable'] = false
gitlab_workhorse['enable'] = false
gitlab_kas['enable'] = false
prometheus['enable'] = false
alertmanager['enable'] = false
gitlab_exporter['enable'] = false

gitlab_rails['auto_migrate'] = false
praefect['enable'] = true
# Schema migration is a separate, manual, one-node operation.
praefect['auto_migrate'] = false

praefect['configuration'] = {
  # Disable the plaintext listener; serve only TLS on 3305.
  listen_addr: nil,
  tls_listen_addr: '0.0.0.0:3305',
  tls: {
    certificate_path: '/etc/gitlab/ssl/server.crt',
    key_path: '/etc/gitlab/ssl/server.key',
  },
  auth: {
    # Set via vaulted praefect_external_token in group_vars/praefect.yml.
    token: 'REPLACE_WITH_VAULTED_PRAEFECT_EXTERNAL_TOKEN',
  },
  database: {
    # Values are supplied from the vaulted bastion group_vars.
    host: 'REPLACE_WITH_RDS_ENDPOINT',
    port: 5432,
    user: 'praefect',
    password: 'REPLACE_WITH_VAULTED_PRAEFECT_DB_PASSWORD',
    dbname: 'praefect_production',
    sslmode: 'verify-full',
    sslrootcert: '/etc/gitlab/ssl/rds-global-bundle.pem',
  },
  virtual_storage: [
    {
      name: 'default',
      default_replication_factor: 2,
      node: [
        {
          storage: 'gitaly-1',
          address: 'tls://gitaly-1.repo-data.internal:9999',
          token: 'REPLACE_WITH_VAULTED_PRAEFECT_INTERNAL_TOKEN',
        },
        {
          storage: 'gitaly-2',
          address: 'tls://gitaly-2.repo-data.internal:9999',
          token: 'REPLACE_WITH_VAULTED_PRAEFECT_INTERNAL_TOKEN',
        },
      ],
    },
  ],
}
