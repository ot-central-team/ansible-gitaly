# Shared GitLab package installation

This role installs the pinned GitLab EE package on both Gitaly and Praefect
hosts. It configures the package repository, suppresses automatic reconfiguration,
and holds the package version. It does not configure services or data disks.

Its single operation uses `tasks/main.yml`, with package defaults in
`defaults/main.yml`. Fact gathering is required for the Ubuntu validation.
Existing `gitlab_package_*` variables and `gitlab_ee_version` are unchanged.

```bash
ansible-playbook playbooks/configure_cluster.yml --tags installation --ask-vault-pass
```

The playbook runs OS/firewall preparation on Gitaly and Praefect first, then this
role only on Gitaly and Praefect. Use `--tags installation` to select only
package installation, or `--tags common` for OS/firewall preparation only.
