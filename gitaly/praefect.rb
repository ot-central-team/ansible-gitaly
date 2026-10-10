# Same settings on all THREE Praefect VMs; each VM has its OWN TLS key/cert.
prometheus_monitoring['enable'] = false
postgresql['enable'] = false
redis['enable'] = false
nginx['enable'] = false
puma['enable'] = false
sidekiq['enable'] = false
gitlab_workhorse['enable'] = false
gitlab_kas['enable'] = false
gitaly['enable'] = false
gitlab_rails['auto_migrate'] = false
praefect['enable'] = true
praefect['auto_migrate'] = false
praefect['configuration'] = {
  listen_addr: '',
  tls_listen_addr: '0.0.0.0:3305',
  tls: {
    certificate_path: '/etc/gitlab/ssl/current/server.crt',
    key_path: '/etc/gitlab/ssl/current/server.key'
  },
  auth: { token: 'REPLACE_PRAEFECT_EXTERNAL_TOKEN' },
  database: {
    host: 'REPLACE_RDS_ENDPOINT', port: 5432,
    user: 'praefect', password: 'REPLACE_PRAEFECT_DB_PASSWORD',
    dbname: 'praefect_production', sslmode: 'verify-full',
    sslrootcert: '/etc/gitlab/ssl/rds-global-bundle.pem'
  },
  virtual_storage: [{
    name: 'default', default_replication_factor: 3,
    node: [
      { storage: 'gitaly-1', address: 'tls://gitaly-1.gitaly-lab.internal:9999', token: 'REPLACE_GITALY_INTERNAL_TOKEN' },
      { storage: 'gitaly-2', address: 'tls://gitaly-2.gitaly-lab.internal:9999', token: 'REPLACE_GITALY_INTERNAL_TOKEN' },
      { storage: 'gitaly-3', address: 'tls://gitaly-3.gitaly-lab.internal:9999', token: 'REPLACE_GITALY_INTERNAL_TOKEN' }
    ]
  }]
}
