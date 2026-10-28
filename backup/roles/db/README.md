# Database provisioning role

This role runs on the bastion to create the PostgreSQL login role and database
and grant the required access. It does not run Praefect schema migrations.

Use `playbooks/configure_cluster.yml --tags database` to run it. Existing `praefect_db_*`
variables remain unchanged for compatibility with inventory and Praefect configuration.
