# Gitaly and Praefect with Ansible

Configure existing Ubuntu VMs for Gitaly repository storage, Praefect routing,
PostgreSQL database access, and optional private-CA TLS for the RPC listeners. This repository does not create
EC2 instances, attach EBS volumes in AWS, or provision RDS, DNS or load balancers.

## What runs where

| Host | Purpose |
|---|---|
| Ansible controller | Runs playbooks and connects to VMs over SSH. It can be the bastion. |
| Bastion | Connects to PostgreSQL to create the Praefect database/user. Holds the CA private key and signs server certificates. |
| Gitaly VMs | Store repositories on their data volumes and serve RPC on port **8075** by default (plaintext); TLS is opt-in on **9999**. |
| Praefect VMs | Route repository requests to Gitaly, coordinate replication and store metadata in PostgreSQL. Serve plaintext RPC on port **2305** by default; TLS is opt-in on **3305**. |
| External PostgreSQL | Stores Praefect metadata; accessed on port **5432**. |

Server private keys stay on their VMs. The CA private key stays on the bastion;
only CSRs and public certificates travel between hosts.

## 1. Set inventory and variables

Edit [inventory/lab/hosts.ini](inventory/lab/hosts.ini), for example:

```ini
[gitaly]
gitaly-1.internal
gitaly-2.internal

[praefect]
praefect-1.internal
praefect-2.internal

[bastion]
bastion.internal
```

Use real, resolvable hostnames and exactly one bastion. Membership controls where
roles run: whichever host is under `[bastion]` receives the CA and database tasks.
Check this before running; the checked-in inventory may reflect a previous lab.

| Location | What to configure |
|---|---|
| `ansible.cfg` | Inventory path and SSH private-key path for your controller. |
| `inventory/lab/group_vars/all/vars.yml` | SSH user, approved network/SSH ranges, pinned GitLab version, CA paths, and Gitaly/Praefect transport and port defaults. |
| `inventory/lab/group_vars/gitaly.yml` | Data disk attachment name, selected Gitaly firewall port and callback settings. |
| `inventory/lab/group_vars/praefect/vars.yml` | Replication factor, selected Praefect firewall port and extra certificate DNS names (for TLS opt-in). |
| `inventory/lab/group_vars/bastion/vars.yml` | PostgreSQL endpoint, database and usernames. |
| `inventory/lab/host_vars/<inventory-hostname>.yml` | Node-specific storage name, blank-disk formatting opt-in and renewal target ID where needed. |
| Group `vault.yml` files | Passwords, tokens and the CA key passphrase. Encrypt with Ansible Vault. |

Role defaults provide fallback values. `group_vars/all/` applies to every host;
matching group variables override it, and host variables supply per-node values.
Keep real passwords, private keys and Vault unlock passwords out of Git.

Before continuing:

- Ensure SSH and sudo work from the controller. Update its private-key path.
- Set approved CIDRs: `0.0.0.0/0` means everyone, not your private network.
- Attach each Gitaly data volume as `/dev/sdb` in AWS. Set
  `gitaly_format_data_disk: true` only for a confirmed blank data disk.
- Set each Gitaly host's `gitaly_storage_name`; choose a replication factor no
  greater than the number of Gitaly nodes.
- Allow required private traffic through AWS security groups and UFW: Gitaly
  **8075** by default (or **9999** with Gitaly TLS), Praefect **2305** by
  default (or **3305** with Praefect TLS), PostgreSQL **5432**, and SSH **22**.
- Point the NLB target group and Rails endpoint at Praefect **2305** for the
  plaintext default. If opting into Praefect TLS, use **3305** and configure
  the Rails chart's `tlsEnabled` plus certificates/SANs consistently.

## 2. Configure the cluster

Run from the repository root on the controller:

```bash
ansible-galaxy collection install -r collections/requirements.yml
ansible all -m ping --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --ask-vault-pass
```

The playbook executes these stages in order:

| Stage/tag | Role/task | What it does |
|---|---|---|
| `common` | `common` | Prepare Gitaly/Praefect packages and UFW rules. |
| `storage` | `gitaly/attach_storage.yml` | Identify the attached data disk, prepare ext4 where authorized, and mount it persistently at `/var/opt/gitlab/git-data`. |
| `installation` | `installation` | Install the pinned GitLab package on both VM types, skipping automatic all-in-one reconfiguration. |
| `database` | `db` | Create the Praefect database/login and permissions from the bastion. |
| `ca` | `tls/ca_generation.yml` | Create or verify the private CA on the bastion. |
| `certificates` | `tls/distribution_tls.yml` | Conditionally issue server certificates and install CA trust when a Gitaly or Praefect RPC TLS mode is enabled. |
| `gitaly` | `gitaly/configuration.yml` | Render Gitaly's `gitlab.rb` and apply configuration. |
| `praefect` | `praefect` | Render Praefect's `gitlab.rb`, configure database/Gitaly connections and apply configuration. |
| `next_steps` | Playbook output | Print the manual migration and verification commands. |

For an already prepared cluster, rerun a specific stage using its tag:

```bash
ansible-playbook playbooks/configure_cluster.yml \
  --tags praefect --ask-vault-pass
```

Selected stages require their earlier prerequisites. Configuration changes may
restart services. Normal bootstrap preserves existing certificates and private keys.

Gitaly RPC is plaintext on port 8075 by default and Praefect connects using
`tcp://`. Praefect's listener is also plaintext on port 2305 by default. In the
EKS chart, the external Praefect `tlsEnabled` setting is false and the NLB must
target port 2305. TLS for either service is an independent opt-in
(`gitaly_enable_tls` for Gitaly, `praefect_enable_tls` for Praefect), using
ports 9999 and 3305 respectively. Changing a live cluster's transport requires
coordinating each client, server, load balancer and firewall in a maintenance
window. PostgreSQL TLS is separate and remains enabled by default.

## 3. Migrate and verify

After initial configuration, run migrations on **one Praefect VM only**:

```bash
sudo -u git -- /opt/gitlab/embedded/bin/praefect \
  -config /var/opt/gitlab/praefect/config.toml sql-migrate
```

Then run on **each Praefect VM**:

```bash
sudo gitlab-ctl status praefect
sudo gitlab-ctl praefect check
```

On each Gitaly VM:

```bash
sudo gitlab-ctl status gitaly
sudo mountpoint /var/opt/gitlab/git-data
```

A successful playbook does not replace these health checks. Future version
upgrades can require new database migrations; do not run migrations concurrently.

## 4. Renew certificates separately

Renewal preserves the CA and server private keys. It updates CSRs/certificates
when DNS names change, certificates reach the renewal age, or expiry approaches.

For a lab or agreed maintenance window **with application traffic stopped**:

```bash
ansible-playbook playbooks/renew_tls.yml \
  --limit praefect --ask-vault-pass \
  -e tls_renew_maintenance_window=true
```

Remove `--limit praefect` to include Gitaly. Nodes restart one at a time;
maintenance mode bypasses NLB draining and does not stop traffic for you.

For live Praefect renewal, configure NLB draining first. The optional controller
timer checks daily and renews at 30 days by default. It is not enabled by bootstrap.
See [TLS renewal](roles/tls/RENEWAL.md) for draining, timer setup and limitations.

Role details: [Gitaly](roles/gitaly/README.md) ·
[Praefect](roles/praefect/README.md) · [Database](roles/db/README.md) ·
[TLS](roles/tls/README.md) · [Installation](roles/installation/README.md).
