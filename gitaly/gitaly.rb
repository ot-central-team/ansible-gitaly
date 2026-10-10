# Reference only; roles/gitaly_config renders this from inventory and vaulted vars.
# Each Gitaly node gets its own name and certificate. The current lab has two nodes.

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
gitlab_rails['internal_api_url'] = 'REPLACE_WITH_GITLAB_INTERNAL_API_URL'
gitaly['enable'] = true
gitaly['gitlab_secret'] = 'REPLACE_WITH_VAULTED_GITLAB_SHELL_SECRET'

gitaly['configuration'] = {
  listen_addr: nil, # Disable plaintext TCP.
  tls_listen_addr: '0.0.0.0:9999',
  tls: {
    certificate_path: '/etc/gitlab/ssl/server.crt',
    key_path: '/etc/gitlab/ssl/server.key',
  },
  auth: {
    token: 'REPLACE_WITH_SHARED_VAULTED_PRAEFECT_INTERNAL_TOKEN',
  },
  storage: [
    {
      name: 'REPLACE_WITH_THIS_HOST_STORAGE_NAME',
      path: '/var/opt/gitlab/git-data/repositories',
    },
  ],
}
