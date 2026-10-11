# Gitaly lab — Ansible starter layout

## Configure the cluster in order

Run the complete bootstrap from the Ansible controller:

```bash
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook playbooks/configure_cluster.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --ask-vault-pass
```

The playbook runs OS/firewall preparation, Gitaly volume attachment, GitLab
package installation, database/user provisioning from the bastion, CA generation
on the bastion, certificate distribution, Gitaly configuration, then Praefect
configuration. It prints manual migration and health-check commands at the end;
it does not execute migrations or declare the cluster healthy.

Before running, configure inventory, the shared AWS data attachment name, formatting opt-in
for new disks, package version, and vaulted credentials. AWS VMs, RDS, private
DNS and network access must already exist. In particular, allow Praefect and
Gitaly peers to reach Gitaly TCP 9999, and the bastion/Praefect nodes to reach RDS
TCP 5432. No AWS resources are provisioned by this playbook.

Optional stage tags: `common`, `storage`, `installation`, `database`, `ca`,
`certificates`, `gitaly`, `praefect`, `next_steps`. Selected stages assume their
prerequisites are already complete. Avoid limiting a first full bootstrap to
workload hosts: database and CA setup require the bastion. Use the stage tags for focused operations; there is only one cluster playbook.

Reconfiguration can restart services; serial execution is not a zero-downtime
guarantee. HAProxy gets common preparation only; Rails, HAProxy service setup
and automatic TLS renewal are not part of this bootstrap.


`playbooks/configure_cluster.yml --tags common,installation` first runs the `common` role on Gitaly, Praefect, and HAProxy, then installs the pinned GitLab package on Gitaly and Praefect only. AWS networking, EC2, DNS, and RDS instance creation remain separate.

## What Ansible is

Ansible is an automation tool that connects from a **control node** (your laptop or admin machine) to target Linux hosts, usually over SSH. It runs declarative tasks: describe the desired state (for example, a package installed or a config file present), and Ansible applies changes. A **playbook** says which hosts to act on and which **roles** to apply. An **inventory** identifies hosts and groups them. Variables hold environment-specific settings. Roles organize reusable tasks, templates, files, and defaults by responsibility.

For this lab, inventory groups are `gitaly`, `praefect`, and `haproxy`. They are not separate roles per VM: three Gitaly servers share the `gitaly` role, with node-specific values such as storage name supplied by inventory variables.

## Suggested layout

```text
ansible.cfg
inventory/
  lab/
    hosts.ini             # VM addresses grouped by role
    group_vars/
      all.yml             # shared, non-secret configuration
      gitaly.yml          # Gitaly-specific settings (to add)
      praefect.yml        # Praefect/RDS settings (to add)
      haproxy.yml         # proxy backend settings (to add)
      bastion.yml         # bastion-only RDS administration settings (Vault)
playbooks/
  configure_cluster.yml   # ordered setup; stage tags for individual operations
roles/
  common/                 # common OS prep and service-account prerequisites
  db/                     # create the Praefect RDS role and database from bastion
  installation/           # shared GitLab package installation
  gitaly/                 # Gitaly storage and service configuration
  praefect/               # Praefect config, RDS CA, migrations/health checks
  haproxy/                # TCP passthrough config and runtime checks
  tls/                    # CA generation, certificate distribution; renewal placeholder
```

Each role will eventually contain `tasks/main.yml` (actions), `defaults/main.yml` (overridable safe defaults), `templates/` (Jinja2 config templates), and optionally `handlers/main.yml` (restart/reload only when configuration changes). `files/` is for static assets. Add role subfolders only when there is a real need; do not create one role per server.

## Why these roles

- `common`: shared OS prerequisites and first-install preparation.
- `installation`: shared GitLab package installation on both Gitaly and Praefect.
- `gitaly`: independently selected data disk preparation and service configuration, targeting only Gitaly.
- `praefect`: service configuration on the three Praefect nodes. Database creation/migration must be guarded and run once, not independently on every node.
- `haproxy`: TCP passthrough config on the dedicated proxy only.
- `tls`: separate task files for CA generation on the bastion and certificate issuance/distribution to workload hosts. CA signing stays on the bastion. Renewal remains a placeholder.

TLS renewal should be a separate, deliberate playbook/workflow, not part of every normal deployment run. Praefect renewal needs a drain/verify/ready sequence via HAProxy; Gitaly renewal needs one node at a time and replica health checks. Ansible can automate those steps, but a service restart may still interrupt active RPCs; do not promise zero downtime.

## First manual-lab workflow

1. Complete the manual runbook and record actual host addresses, exact package version, paths, and successful health checks.
2. Install Ansible on the control node and configure SSH access. This machine's private SSH key stays on the control node.
3. Fill `inventory/lab/hosts.ini`; test connectivity with `ansible all -m ping`.
4. Automate a low-risk step first (for example, common packages), compare its result with the manual process, then continue role by role.
5. Use `--check --diff` where supported, review proposed changes, and run against one test node before expanding.
6. Store tokens, DB passwords, and other secrets with Ansible Vault. Do not commit vault passwords, leaf private keys, or the CA private key. Do not let Ansible initialize/replace the CA during routine renewal.
7. Test rolling TLS renewal on a disposable cluster before relying on it.

## Run the common role

Run from this project directory on your control machine. Install Ansible there if needed (for Ubuntu: `sudo apt update && sudo apt install -y ansible`), then install the UFW collection:

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

Edit `inventory/lab/hosts.ini`: put one reachable VM IP on each line under its group. No actual host addresses have been populated yet. Use SSH key authentication; keep your private key on your control machine.

For example, with **sample addresses only**:

```ini
[gitaly]
172.31.39.202

[praefect]
172.31.39.203

[haproxy]
172.31.39.204
```

The group names match `group_vars/gitaly.yml`, `group_vars/praefect.yml`, and `group_vars/haproxy.yml`. Ansible loads the matching file for each IP; `group_vars/all.yml` applies to every IP. To target one VM with `--limit`, give its inventory IP.

The firewall settings are in `inventory/lab/group_vars/`:

| Setting | File | Value |
|---|---|---|
| Internal source range | `all.yml` | `cluster_cidr: 172.31.32.0/20` |
| SSH sources | `all.yml` | `ssh_sources`, initially the same subnet |
| Gitaly TCP port | `gitaly.yml` | `common_service_ports: [9999]` |
| Praefect TCP port | `praefect.yml` | `common_service_ports: [3305]` |
| HAProxy internal TCP port | `haproxy.yml` | `common_service_ports: [443]` |

`172.31.39.202/20` is a host address with a prefix; its network is `172.31.32.0/20`, covering `172.31.32.0` through `172.31.47.255`. CIDR `/20` describes the network size, not a port. Confirm all intended nodes are in this range.

UFW rules match source IPs/CIDRs and do not dynamically resolve DNS names. For a bastion whose private IP may change, allow its subnet CIDR in UFW and restrict the AWS security group to the bastion's security group. For a single fixed bastion address, use its private IP with `/32`.

For SSH through a bastion, configure the jump host in your local `~/.ssh/config`, for example:

```sshconfig
Host gitaly-lab-bastion
    HostName REPLACE_BASTION_PUBLIC_IP
    User ubuntu
    IdentityFile ~/.ssh/lab-key.pem

Host 172.31.*.*
    User ubuntu
    IdentityFile ~/.ssh/lab-key.pem
    ProxyJump gitaly-lab-bastion
```

Use the target VMs' private IPs as inventory entries with this example. The bastion's own setup is outside this playbook. If connecting directly over public IPs instead, add your control machine's public source IP `/32` to `ssh_sources` **before running**. AWS security groups must also permit the connection.

Check connectivity and syntax, then run against one node:

```bash
ansible gitaly:praefect -m ping --private-key ~/.ssh/lab-key.pem
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --syntax-check
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --limit REPLACE_FIRST_GITALY_IP --private-key ~/.ssh/lab-key.pem
```

Keep your SSH session open and verify a new connection after the first run. Then run either group, or both:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --limit gitaly --private-key ~/.ssh/lab-key.pem
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --limit praefect --private-key ~/.ssh/lab-key.pem
# All inventoried Gitaly, Praefect and HAProxy hosts:
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --private-key ~/.ssh/lab-key.pem
```

Add `--ask-become-pass` if your SSH user requires a sudo password. Hosts are processed one at a time. SSH and service allow rules are installed before default deny and UFW activation. The role refreshes apt metadata but does not upgrade all packages.

Re-running keeps the requested rules present without duplicating them. Existing UFW rules are preserved: changing a source or port adds the new allowance but does not remove the old one. Review `sudo ufw status numbered` and remove obsolete allowances deliberately. HAProxy currently permits internal port 443 only; approved public client access must be configured separately.

`--check --diff` is useful after UFW is installed. On a fresh VM, check mode cannot actually install UFW, so subsequent UFW tasks may fail because its executable is absent.

The cluster playbook includes OS/firewall preparation and GitLab package installation. Service configuration and TLS use separate playbooks. Module references: [Ansible UFW](https://docs.ansible.com/projects/ansible/latest/collections/community/general/ufw_module.html) and [Ansible apt](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_module.html).

## Install the GitLab package on storage VMs

The `installation` role installs the same exact GitLab EE package version on Gitaly and Praefect. It adds the official apt repository, creates `/etc/gitlab/skip-auto-reconfigure` before package installation so the storage VMs do not start as standalone GitLab instances, and holds the installed version. It does not write `gitlab.rb` or configure Gitaly/Praefect services.

Set `gitlab_ee_version` in `inventory/lab/group_vars/all.yml` to the exact package version compatible with the GitLab application, for example `18.8.2-ee.0` (example only). The value must not be blank. GitLab's official Ubuntu install guide covers repository and package setup: [GitLab package install](https://docs.gitlab.com/install/package/ubuntu/).

The default preparation run performs both stages. To select only firewall preparation, use `--tags common`; to select only package installation, use `--tags installation`. Run on one node first, then expand:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --syntax-check
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --limit gitaly-1.repo-data.internal
ansible-playbook playbooks/configure_cluster.yml --tags common,installation --limit gitaly:praefect
```

Use the inventory hostname for the first command if yours differs. The role requires outbound access to GitLab's package repository and package storage URLs. After package installation, follow the manual runbook's bootstrap configuration to create the `git` service account before installing certificate keys.

## Prepare the Praefect database from the bastion

Add the bastion private DNS name or private IP under `[bastion]` in `inventory/lab/hosts.ini`. The cluster playbook’s `database` stage targets only this group; its PostgreSQL modules execute on the bastion and connect to RDS. It creates the Praefect login role/database and grants database/schema access. It does not create Praefect's application tables; one designated Praefect node runs GitLab's schema migrations later.

Install the collection and encrypt the bastion variables file:

```bash
ansible-galaxy collection install -r collections/requirements.yml
ansible-vault encrypt inventory/lab/group_vars/bastion.yml
```

Edit the encrypted file with `ansible-vault edit inventory/lab/group_vars/bastion.yml`; set the exact RDS endpoint and both passwords (`praefect_db_master_password` and `praefect_db_password`). The role installs `python3-psycopg2` on the bastion. Then validate and run:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags database --syntax-check
ansible-playbook playbooks/configure_cluster.yml --tags database --ask-vault-pass
```

The bastion must be reachable by Ansible and have network access to private RDS on TCP 5432. The RDS security group should allow 5432 from the bastion and Praefect security groups. Keep credentials Vault-encrypted; password-bearing tasks suppress output.

## Prepare Gitaly repository disks

On every Gitaly VM, attach the dedicated EBS repository volume using the AWS
attachment name `/dev/sdb`. Keep the root volume on its existing root-device
mapping. Configure the shared convention in `inventory/lab/group_vars/gitaly.yml`:

```yaml
gitaly_data_attachment_name: /dev/sdb
```

No per-host volume ID is required. The role installs `nvme-cli`, reads the AWS
attachment name from each EBS NVMe controller, and requires exactly one match.
Linux may call that disk `/dev/nvme1n1` or a different NVMe number; the AWS
attachment name is what selects it. This workflow requires Nitro/NVMe EBS.
It stops if the attachment is absent/ambiguous, partitioned, layered, read-only,
mounted elsewhere, has unexpected filesystem signatures, or would cover
existing files at the target mountpoint. It does not attach volumes in AWS.

For a confirmed new blank data disk, set `gitaly_format_data_disk: true` in its
host variables. The default is false; existing lab opt-ins are preserved.
Only a disk without a filesystem or detected signatures is formatted. Existing
whole-disk ext4 volumes are reused. The filesystem UUID is still used in fstab
at `/var/opt/gitlab/git-data`. Existing deployments must confirm the attachment
name in AWS before rerunning; the role will not silently choose another disk.

```bash
ansible-playbook playbooks/configure_cluster.yml --tags storage --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags storage --limit gitaly-1.repo-data.internal --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags storage --ask-vault-pass
```

Disk discovery is read-only, including in check mode. On fresh VMs check mode
cannot install missing `nvme-cli` or create a filesystem/UUID, so a complete
fresh-disk dry run is not supported.
