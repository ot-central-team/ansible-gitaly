# Gitaly lab — Ansible starter layout

The `common` role and `playbooks/prepare.yml` now automate apt cache refresh, UFW installation, firewall rules, and enabling UFW. The remaining roles are still scaffolds. First build and understand the lab manually using `gitaly/README.md`; then automate one tested manual step at a time. Ansible should configure the six storage VMs and HAProxy VM. AWS networking, EC2, DNS, and RDS remain out of scope initially because the current runbook creates them in the AWS Console.

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
playbooks/
  prepare.yml             # safe OS prerequisites, package installation
  configure.yml           # disks, TLS material, Gitaly, Praefect, HAProxy
  renew_tls.yml           # separate, explicitly run rolling renewal
roles/
  common/                 # common OS prep and service-account prerequisites
  gitlab_package/         # exact package repository/version installation
  gitaly/                 # Gitaly-only config and repository data mount
  praefect/               # Praefect config, RDS CA, migrations/health checks
  haproxy/                # TCP passthrough config and runtime checks
  tls_certificates/       # install pre-issued CA/leaf material; no CA key on VMs
```

Each role will eventually contain `tasks/main.yml` (actions), `defaults/main.yml` (overridable safe defaults), `templates/` (Jinja2 config templates), and optionally `handlers/main.yml` (restart/reload only when configuration changes). `files/` is for static assets. Add role subfolders only when there is a real need; do not create one role per server.

## Why these roles

- `common`: shared OS prerequisites and first-install preparation.
- `gitlab_package`: common exact-version GitLab EE package installation on all six storage nodes.
- `gitaly`: Gitaly-specific data disk mount and service configuration; applied only to `gitaly` hosts.
- `praefect`: service configuration on the three Praefect nodes. Database creation/migration must be guarded and run once, not independently on every node.
- `haproxy`: TCP passthrough config on the dedicated proxy only.
- `tls_certificates`: distribute public CA trust and each host's own **pre-issued** leaf certificate/key with strict ownership/modes. Keep CA signing outside this role and off the VMs.

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
ansible-playbook playbooks/prepare.yml --syntax-check
ansible-playbook playbooks/prepare.yml --limit REPLACE_FIRST_GITALY_IP --private-key ~/.ssh/lab-key.pem
```

Keep your SSH session open and verify a new connection after the first run. Then run either group, or both:

```bash
ansible-playbook playbooks/prepare.yml --limit gitaly --private-key ~/.ssh/lab-key.pem
ansible-playbook playbooks/prepare.yml --limit praefect --private-key ~/.ssh/lab-key.pem
# All inventoried Gitaly, Praefect and HAProxy hosts:
ansible-playbook playbooks/prepare.yml --private-key ~/.ssh/lab-key.pem
```

Add `--ask-become-pass` if your SSH user requires a sudo password. Hosts are processed one at a time. SSH and service allow rules are installed before default deny and UFW activation. The role refreshes apt metadata but does not upgrade all packages.

Re-running keeps the requested rules present without duplicating them. Existing UFW rules are preserved: changing a source or port adds the new allowance but does not remove the old one. Review `sudo ufw status numbered` and remove obsolete allowances deliberately. HAProxy currently permits internal port 443 only; approved public client access must be configured separately.

`--check --diff` is useful after UFW is installed. On a fresh VM, check mode cannot actually install UFW, so subsequent UFW tasks may fail because its executable is absent.

This playbook prepares the firewall only; it does not yet install or configure GitLab services, certificates, or HAProxy. Module references: [Ansible UFW](https://docs.ansible.com/projects/ansible/latest/collections/community/general/ufw_module.html) and [Ansible apt](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_module.html).

