# Gitaly VMs ONLY. Replace placeholders before copying to /etc/gitlab/gitlab.rb.
# Fill four values: GitLab hostname, shared Shell secret, internal token, node name.
# Use the same secrets on all three nodes; each node has its own name and TLS files.
roles(['gitaly_role'])
prometheus_monitoring['enable'] = false
gitlab_rails['auto_migrate'] = false
gitlab_rails['internal_api_url'] = 'https://REPLACE_EXISTING_GITLAB_HOST'
gitaly['gitlab_secret'] = 'REPLACE_EXISTING_GITLAB_SHELL_SECRET'
gitaly['configuration'] = {
  listen_addr: '', # Disable plaintext TCP.
  tls_listen_addr: '0.0.0.0:9999', # Listen on this VM's interfaces; no fixed IP needed.
  tls: {
    certificate_path: '/etc/gitlab/ssl/current/server.crt',
    key_path: '/etc/gitlab/ssl/current/server.key'
  },
  auth: { token: 'REPLACE_GITALY_INTERNAL_TOKEN' },
  storage: [{
    name: 'REPLACE_NODE_NAME', # gitaly-1, gitaly-2, or gitaly-3
    path: '/var/opt/gitlab/git-data/repositories'
  }]
}
