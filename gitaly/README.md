# Small Gitaly Cluster POC — start here

This is a **separate repository-storage lab**, not the full GitLab deployment. Create AWS resources in the Console, then run the commands on the indicated machine. Nothing has been deployed by creating these files.

You will build three Praefect VMs, three Gitaly VMs, one dedicated HAProxy VM (**seven VMs total**), and one private RDS PostgreSQL database. Rails, Sidekiq, GitLab Shell, and the rest of GitLab will run separately in the application account. No EKS, Redis, S3, or runners are created here.

### How to follow this guide

Go in section order. Read the machine name above each command block before running it. `§8` means “section 8.” Replace every `REPLACE_*` value with your real value; do not paste a placeholder into a running configuration. If a command fails, read the error before continuing.

| Where you work | What you do there |
|---|---|
| AWS Console | Create networking, VMs, DNS records, and RDS |
| Your laptop | SSH into VMs, create certificates, and upload files |
| Gitaly-1, 2, 3 | Prepare repository disks and run Gitaly |
| Praefect-1, 2, 3 | Run Praefect; use Praefect-1 to initialize the shared RDS database once |
| HAProxy-1 | Install the TCP proxy only; no GitLab package or certificate keys |
| Kubernetes admin machine, later | Connect GitLab on EKS to this storage cluster |

**EKS is not deployed yet? That is okay.** Build the storage side through §12 first. In §3 choose your future GitLab version, URL and shared secret. Return to §§13–14 after GitLab is installed. TLS/network checks can run now; end-to-end clone/push and Rails callback checks must wait.

## 1. Decisions before spending money

### ALB is not the right load balancer

Praefect needs **TCP passthrough**, not an ALB/HTTP/gRPC proxy. GitLab uses sidechannels that an HTTP/2 load balancer cannot handle. Use an NLB with a TCP listener, or HAProxy in TCP mode. Port 443 here carries encrypted repository RPC, **not a browser website**. [GitLab load-balancer requirement](https://docs.gitlab.com/administration/gitaly/praefect/configure/#configure-the-load-balancer)

I cannot verify your account's NLB eligibility. Free plans, credits, quotas, and account restrictions are different things; do not assume ALB is free or substitute it for a blocked NLB. Check Billing and the exact Console error. [AWS ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/)

**Main path in this lab:** HAProxy on its own VM, `haproxy-1`, with an Elastic IP and a public DNS name. The six storage VMs run only their respective Praefect/Gitaly services. This isolates proxy maintenance from Praefect maintenance, but losing the single HAProxy VM still loses the entry point. Single-AZ RDS is another single point of failure. A managed NLB is an alternative, but its separate runbook (`NLB-OPTION.md`) is not currently present in this folder.

### Self-signed is okay, if you establish trust

Use one self-signed **private CA**, then six separate server certificates signed by it. Every client must trust the CA and verify the hostname. Do not disable verification. TLS encrypts traffic; the separate Praefect/Gitaly tokens authorize it. “Internal” does not remove the need for either.

This lab's cross-account connection is **public, TLS-encrypted, and IP-allowlisted**, not entirely internal. No VPC peering is necessary for that route. For production, prefer private connectivity and an internal TCP endpoint.

### Cost compromise: no NAT gateway

The seven VMs have public IPv4 addresses and an Internet Gateway route, but backend connections use private addresses. Only the entry point accepts TCP443 from approved callers; SSH is restricted to your IP; backend ports are never internet-open. RDS remains private. An Internet Gateway alone would NOT give an IPv4-only private VM outbound internet: this path deliberately gives the VMs public addresses. [AWS internet access requirements](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)

This costs money: seven EC2 instances, EBS, public IPv4 addresses, RDS, DNS, and data transfer. Burstable CPU credits can also cost money. It is **not a free-tier guarantee**, a production security design, or sizing for 2,000 users.

## 2. Architecture and work order

In plain words: **HAProxy chooses a Praefect server; Praefect coordinates repository operations on Gitaly; Gitaly stores the Git files.** RDS stores Praefect's tracking information. RDS does not contain the repositories themselves.

```text
Other AWS account: existing GitLab (Rails / Sidekiq / Shell / Toolbox)
        |
        | TLS + Praefect token; only approved egress IPs can connect
        v
praefect-lab.tyagi.fun:443 -> Elastic IP -> dedicated haproxy-1
                                                |
                              private TCP passthrough to TLS3305
                                                v
                           +------------+------------+------------+
                           | Praefect-1 | Praefect-2 | Praefect-3 |
                           |    AZ-a    |    AZ-b    |    AZ-c    |
                           +------------+------------+------------+
                                 |         |
                                 |         +-- TLS5432 --> RDS (metadata)
                         TLS9999 |
                                 v
                           +----------+----------+----------+
                           | Gitaly-1 | Gitaly-2 | Gitaly-3 |
                           |   AZ-a   |   AZ-b   |   AZ-c   |
                           +----------+----------+----------+
                            Separate EBS; replication factor 3

Storage VMs -> existing GitLab HTTPS internal API (reverse callback)
Gitaly nodes -> each other; Gitaly -> Praefect entry point over private IP
```

All seven VMs and RDS are in one new VPC in `ap-south-1`. Each Praefect can reach all three Gitaly nodes, not just its same-AZ partner. Gitaly holds repositories; RDS holds Praefect metadata, not Git files. Replication is not a backup.

Order: agree client details → VPC/SGs → seven VMs/DNS → RDS → package/certificates on six storage VMs → Gitaly → Praefect → HAProxy on its dedicated VM → connect GitLab → test → rehearse renewal.

## 3. Fill in this worksheet with the other account's owner

| Item | Value you need |
|---|---|
| GitLab application version | Existing exact version, or choose the version you will install later; NOT the Helm chart version |
| GitLab URL | For example `https://gitlab.tyagi.fun`; it must work before callback/push tests, not before building storage |
| Client egress addresses | ALL stable public IPs used by the GitLab pods/nodes, each `/32` |
| Your admin address | Your current public IPv4 `/32` |
| Callback access | Existing GitLab HTTPS ingress must permit the storage VMs' outbound public IPs |
| Shell callback secret | Reuse the existing GitLab value; for a new installation generate one now and use it in EKS later |
| External Praefect token | Generate NEW; share only with the GitLab administrator |
| Internal Gitaly token | Generate NEW; stays on these six VMs |
| RDS app-role password | Generate NEW; different from the RDS admin password |
| Endpoint | `praefect-lab.tyagi.fun:443` |

Generate each new token/password separately on your laptop with `openssl rand -hex 32`; save in a password manager, not Git or chat. Do **not** invent a new Shell secret when connecting an existing GitLab. Do not copy all Rails secrets to these VMs.

“Egress IP” means the public source IP the other account's connection arrives from. `/32` means exactly one IPv4 address. If EKS does not exist yet, leave its inbound access rules uncreated until you know those IPs; do not temporarily allow the whole internet. Generate the Shell secret once for a new installation and reuse that same value on all three Gitaly nodes and the future GitLab installation.

Stop if the remote GitLab has repositories you need to keep: replacing its `default` storage with this empty cluster is **not a migration**. Use a disposable GitLab POC client, or plan supported repository storage moves separately.

## 4. VPC and subnets — AWS Console

**Where:** AWS Console. **Why:** create one network for the lab, with separate subnets for VMs and the database. A VPC is your AWS network; a subnet is one address range inside it; an Availability Zone (AZ) is a separate location within the region.

Select Mumbai in the Console. First create a Billing budget/alert; alerts do not cap spending.

Check that your account plan permits the chosen EC2/RDS types and has enough regional On-Demand Standard vCPU quota: these seven two-vCPU instances need 14 vCPUs, plus any other running instances. Request access/quota changes before building dependent resources if blocked.

1. **VPC → Your VPCs → Create VPC → VPC only**: name `gitaly-lab`, IPv4 `10.70.0.0/16`, no IPv6 for this lab. Ensure this range does not overlap the remote account if you might peer later.
2. Select the VPC → Actions → Edit VPC settings: enable DNS resolution and DNS hostnames.
3. **Subnets → Create subnet**: create the following in that VPC. Choose three available AZs; a/b/c below are your worksheet labels.

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| lab-public-a | `10.70.0.0/24` | a | HAProxy-1, Praefect-1, Gitaly-1 |
| lab-public-b | `10.70.1.0/24` | b | Praefect-2, Gitaly-2 |
| lab-public-c | `10.70.2.0/24` | c | Praefect-3, Gitaly-3 |
| lab-data-a | `10.70.64.0/24` | a | RDS subnet group |
| lab-data-b | `10.70.65.0/24` | b | RDS subnet group |
| lab-data-c | `10.70.66.0/24` | c | RDS subnet group |

4. **Internet gateways → Create** `gitaly-lab-igw`, then Attach to this VPC.
5. **Route tables → Create** `lab-public-rt`: add `0.0.0.0/0 → Internet Gateway → gitaly-lab-igw`. Explicitly associate ONLY the three public subnets.
6. Create `lab-data-rt`, leave only its automatic VPC-local route, and associate the three data subnets. No Internet Gateway/NAT default route here.
7. Leave default network ACLs unchanged for this POC; use security groups for filtering. Create no NAT gateway and no VPC endpoints.

**What these routes do:** the Internet Gateway gives the public-addressed VMs a route to the internet for updates/downloads. The data subnets have no internet default route, but the VPC-local route still lets Praefect reach RDS privately. A subnet's name does not make it public or private—its routes and the instance's addressing matter.

**Before moving on:** inspect subnet associations. Only the three `lab-public-*` subnets should use `lab-public-rt`; the three `lab-data-*` subnets should use `lab-data-rt`.

## 5. Security groups — AWS Console

**Where:** AWS Console. **Why:** a security group is a firewall attached to a VM/network interface or database. These rules allow only the connections each component needs. “Inbound” means a connection arriving at that component.

**EC2 → Security Groups → Create** the following in `gitaly-lab`. Names intentionally do not start with `sg-`. Create all groups first, then add rules referencing their IDs. Keep default outbound allow-all for the lab; there is no broad inbound rule.

| Group | Attach to | Inbound TCP port → source |
|---|---|---|
| `lab-admin` | All seven VMs | 22 → YOUR public IP `/32` only |
| `lab-frontend` | HAProxy-1 only | 443 → each remote GitLab egress IP `/32`; your `/32`; `lab-gitaly`; `lab-praefect` |
| `lab-praefect` | Three Praefect VMs | 3305 → `lab-frontend`; `lab-gitaly`; `lab-praefect` |
| `lab-gitaly` | Three Gitaly VMs | 9999 → `lab-praefect`; `lab-gitaly` itself |
| `lab-praefect-db` | RDS only | 5432 → `lab-praefect` |

Each semicolon-separated source is a separate rule. A group reference permits the private addresses of interfaces with that group; it does not mean “open to everybody.” You cannot use the other account's EKS security group as the source for a public-internet connection. Never open 3305, 9999, or 5432 to `0.0.0.0/0`.

For example, `lab-praefect-db: 5432 from lab-praefect` means “only VMs carrying the Praefect group can open database connections.” The self-reference on `lab-gitaly` allows Gitaly nodes to communicate with one another. Security groups allow reply traffic automatically; you do not need a separate inbound rule for every response.

### Optional UFW — allow the private range, not individual node IPs

**Your current Ansible environment uses `172.31.32.0/20`** (the subnet containing `172.31.39.202/20`). Use [the common-role run instructions](../README.md#run-the-common-role) to apply it. The manual AWS lab below retains its example `10.70.0.0/16` network; substitute your actual network when following its commands.

AWS security groups above already follow group membership when private IPs change. Keep those rules. If you also use Ubuntu UFW, use **`10.70.0.0/16`** for internal traffic: it covers this lab's entire VPC. UFW then allows the VPC range on the service port, while security groups still restrict which roles can connect. [Ubuntu UFW subnet rules](https://documentation.ubuntu.com/server/how-to/security/firewalls/index.html)

After launching the VMs in §6, run this on **each VM** if you want UFW. Replace the admin placeholder before running; allow SSH before enabling the firewall:

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow proto tcp from REPLACE_ADMIN_PUBLIC_IP/32 to any port 22
```

Then run **only the rule for that VM's role**:

```bash
# Gitaly VMs only
sudo ufw allow proto tcp from 10.70.0.0/16 to any port 9999
```

```bash
# Praefect VMs only
sudo ufw allow proto tcp from 10.70.0.0/16 to any port 3305
```

```bash
# HAProxy VM only
sudo ufw allow proto tcp from 10.70.0.0/16 to any port 443
sudo ufw allow proto tcp from REPLACE_ADMIN_PUBLIC_IP/32 to any port 443
# Repeat for each known GitLab public egress IP; skip until EKS exists.
sudo ufw allow proto tcp from REPLACE_GITLAB_EGRESS_PUBLIC_IP/32 to any port 443
```

Finally, on each VM:

```bash
sudo ufw enable
sudo ufw status numbered
```

Keep your current SSH session open and confirm a second SSH connection works. RDS uses its security group; there is no UFW setup on RDS.

**If IPs change:** these internal UFW rules stay valid anywhere within `10.70.0.0/16`. Update private DNS records and the backend IPs in `haproxy.cfg` when their targets change. Public admin/client IPs are outside this range: update their allowlists, or use a stable public egress IP. Only substitute a public CIDR if the entire range belongs to your trusted admin/client network.

## 6. Launch the seven VMs — AWS Console

**Where:** AWS Console first, then SSH from your laptop. **Why:** each VM gets a clear job and a fixed private address. EBS is the VM's disk; gp3 is the disk type used here. IMDSv2 is AWS's token-based instance-metadata access mode, not a GitLab token.

**EC2 → Key pairs**: create/download a lab key, keep it only on your laptop, mode0600. **Launch instance** seven times: official Canonical Ubuntu 24.04 LTS **x86_64**, encrypted gp3 root 30 GiB, correct subnet, public IP enabled, key pair selected. Under Advanced details require IMDSv2. No AWS access keys are needed on these VMs.

| Name | Private IPv4 (set in network interface settings) | POC instance | Groups |
|---|---|---|---|
| haproxy-1 | `10.70.0.5` | t3.small | lab-admin, lab-frontend |
| praefect-1 | `10.70.0.10` | t3.medium | lab-admin, lab-praefect |
| praefect-2 | `10.70.1.10` | t3.medium | lab-admin, lab-praefect |
| praefect-3 | `10.70.2.10` | t3.medium | lab-admin, lab-praefect |
| gitaly-1 | `10.70.0.20` | t3.large | lab-admin, lab-gitaly |
| gitaly-2 | `10.70.1.20` | t3.large | lab-admin, lab-gitaly |
| gitaly-3 | `10.70.2.20` | t3.large | lab-admin, lab-gitaly |

These are light functional-lab starting sizes, not performance recommendations. On EACH Gitaly add a separate **50 GiB encrypted gp3 data volume** in the same AZ. Use separate volumes, never a shared filesystem. Review delete-on-termination settings so you understand whether data survives termination.

**EC2 → Elastic IP addresses → Allocate → Associate** one to `haproxy-1`. This becomes its public address. Record all seven current public IPs. The six storage VMs' addresses may change on stop/start; update admin connections and the remote GitLab callback allowlist accordingly.

On `haproxy-1`, install only HAProxy and its diagnostic tools in §12. Skip the GitLab package, bootstrap, database-client setup, and certificate installation in §§8–11 on this VM. It needs no GitLab tokens, RDS credentials, or TLS private keys: it passes encrypted TCP traffic through unchanged.

Connect from your laptop (replace the key path and public address):

```bash
chmod 600 /path/to/lab-key.pem
ssh -i /path/to/lab-key.pem ubuntu@REPLACE_VM_PUBLIC_IP
```

Verify a new SSH host fingerprint through a trusted channel before accepting it. AWS EC2 console system logs can show the Ubuntu SSH host-key fingerprints. Never copy your SSH private key onto the VMs.

## 7. DNS — AWS Console

**Where:** Route 53 in AWS Console. **Why:** services connect using names instead of remembering IP addresses. An A record maps a name to an IPv4 address. A public zone is used by public DNS; a private zone is available to associated VPCs. TTL60 means DNS answers may be cached for 60 seconds.

1. **Route 53 → Hosted zones → Create** private zone `gitaly-lab.internal`, associated with this VPC/region.
2. Add six A records: `praefect-1/2/3` and `gitaly-1/2/3` → their respective private IPs from §6.
3. In your **existing publicly delegated** `tyagi.fun` zone, create A record `praefect-lab` → HAProxy-1 Elastic IP, TTL60. If your DNS is elsewhere, create the record there; do not create an undelegated duplicate public zone.
4. Create a SECOND **private** zone named exactly `praefect-lab.tyagi.fun`, associated with this VPC only. Add its apex A record (blank record name) → `10.70.0.5`, TTL60.

Step4 makes the same endpoint resolve privately inside the storage VPC, publicly outside it. This lets Gitaly reach the entry point without internet hairpinning. Do NOT make a private zone for all of `tyagi.fun`: it could shadow the existing GitLab callback hostname. [Route 53 private-zone resolution](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-considerations.html)

On a storage VM, `getent hosts praefect-lab.tyagi.fun` must return `10.70.0.5`. On your laptop, it must return the Elastic IP. `getent hosts gitaly-2.gitaly-lab.internal` on any storage VM must return `10.70.1.20`.

## 8. Create RDS, then connect to it from Praefect-1

**RDS runs the PostgreSQL server. We do not install a database server on Praefect-1.** That VM is only a convenient place to run a database client called `psql`.

There are three different setup tasks:

1. AWS Console creates the PostgreSQL server (RDS).
2. From Praefect-1, you create the database and its login inside RDS.
3. Later, §11 runs Praefect migrations to create the tables inside that database.

### 8.1 Why we keep TLS for RDS

RDS PostgreSQL 15 and newer defaults to `rds.force_ssl=1`, which requires encrypted connections. We also set it explicitly in this lab. Turning TLS off would require changing that policy; it is not just deleting the `.pem` line. We keep TLS enabled. [AWS RDS TLS requirements](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html)

You do **not** generate RDS certificates. AWS handles the server certificate. You download AWS's public CA bundle so Praefect can verify it is connecting to the real RDS server:

- `rds.force_ssl=1`: RDS refuses plaintext connections.
- `sslmode=verify-full`: the client checks the certificate and RDS hostname as well as using encryption.
- `sslrootcert=...`: tells the client where to find the trusted AWS CA file.

The bundle is not a password/private key and is not specific to your database. You can download it before RDS exists. All three Praefect VMs need it for their normal database connections, not only the migration command. Your own Gitaly private CA is unrelated to this AWS bundle.

### 8.2 Create the database server — AWS Console

A **DB subnet group** is the set of subnets RDS may use. A **parameter group** is a collection of PostgreSQL settings, such as requiring TLS. Single-AZ means this POC does not have a standby in another AZ.

1. **RDS → Subnet groups → Create** `lab-praefect-db-subnets`: select the lab VPC and all three data subnets.
2. **Parameter groups → Create** a PostgreSQL instance parameter group matching your chosen major version; set `rds.force_ssl=1`.
3. **Databases → Create database → Standard create → PostgreSQL**. Use a major version supported by the SAME GitLab release as the remote application. For a GitLab19.x lab, PostgreSQL17 is a baseline; choose an available maintained minor. Check compatibility for any other release. [GitLab PostgreSQL version information](https://docs.gitlab.com/administration/package_information/postgresql_versions/)
4. Identifier `gitaly-lab-praefect`, Single DB instance / Single-AZ, `db.t4g.small` starting size, encrypted gp3 20 GiB. Choose Dev/Test or customize; inspect the estimated bill. Do not select a three-instance Multi-AZ cluster accidentally.
5. Master user `lab_admin`, strong unique password stored securely. Set public access **No**, VPC `gitaly-lab`, the subnet group above, ONLY `lab-praefect-db` SG, port5432. Do not automatically connect an EC2 instance/create extra SG rules.
6. Choose the custom parameter group. Leave initial database blank. Enable automated backups (for example 3 days); enable deletion protection if you want a cleanup safety catch. Disable paid extras you do not need after reviewing their tradeoffs.
7. Wait until Available. Apply/reboot for pending parameter changes if required. Copy its actual endpoint; do not substitute a private IP or custom alias for TLS verification.

### 8.3 Install a client and download the AWS CA — on Praefect-1

SSH to `praefect-1`, then run:

```bash
sudo apt-get update
sudo apt-get install -y postgresql-client curl ca-certificates
curl -fL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /home/ubuntu/rds-global-bundle.pem
```

`postgresql-client` installs the command-line client, **not the PostgreSQL server**. `curl` downloads the public CA bundle; we save it as `rds-global-bundle.pem`.

### 8.4 Connect to RDS as its administrator — on Praefect-1

Replace `REPLACE_RDS_ENDPOINT` with the RDS Console endpoint, then run:

```bash
psql "host=REPLACE_RDS_ENDPOINT port=5432 user=lab_admin dbname=postgres sslmode=verify-full sslrootcert=/home/ubuntu/rds-global-bundle.pem" -W
```

Enter the **RDS master password** when asked. `-W` prompts rather than placing the password in the command. `postgres` is the existing database used for this initial administrator connection. When the prompt changes to a PostgreSQL prompt, you are typing SQL to RDS, not Linux commands.

### 8.5 Create Praefect's login and database — inside `psql`

Run the following once. `\password` prompts for the NEW Praefect app-role password from §3, not the master password:

```sql
CREATE ROLE praefect LOGIN;
\password praefect
CREATE DATABASE praefect_production OWNER praefect ENCODING 'UTF8';
REVOKE CONNECT ON DATABASE praefect_production FROM PUBLIC;
GRANT CONNECT ON DATABASE praefect_production TO praefect;
\q
```

`CREATE ROLE` creates the login that Praefect will use. `CREATE DATABASE` creates its database and makes that login the owner. `REVOKE` removes the default connect permission for everyone; `GRANT` allows the Praefect login explicitly. `\q` exits back to the VM terminal. No repository files or tables have been created by these commands yet.

### 8.6 Test the Praefect login — on Praefect-1

```bash
psql "host=REPLACE_RDS_ENDPOINT port=5432 user=praefect dbname=praefect_production sslmode=verify-full sslrootcert=/home/ubuntu/rds-global-bundle.pem" -W
```

Enter the Praefect password. Inside `psql`:

```sql
\conninfo
SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();
\q
```

**Expected:** connection succeeds, and the query returns `t` (true). Stop and fix connection errors before installing Praefect. You do not repeat database creation on the other two VMs: they will connect to this SAME database.

## 9. Prepare disks and install packages

### Data disk — each Gitaly VM only

**Where:** Gitaly-1, then Gitaly-2, then Gitaly-3. **Why:** Git repositories should live on each VM's extra data disk, not accidentally on its operating-system disk.

Inspect `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,SERIAL`. Match the new 50 GiB volume's serial to its EBS volume ID. **Formatting destroys data. Never select the root disk or a disk with existing data.** The device below is only an example; substitute the verified empty data device.

```bash
sudo wipefs --no-act /dev/nvme1n1
sudo mkfs.ext4 /dev/nvme1n1
sudo mkdir -p /var/opt/gitlab/git-data
sudo blkid /dev/nvme1n1
sudo nano /etc/fstab
```

Add `UUID=REPLACE_ACTUAL_UUID /var/opt/gitlab/git-data ext4 defaults 0 2`. Do not add `nofail`: silently starting against the empty root-disk mountpoint is dangerous. Run `sudo mount -a`, then `findmnt /var/opt/gitlab/git-data`. Reboot once and confirm the data filesystem is still mounted before proceeding.

In that block, `wipefs --no-act` only inspects existing filesystem signatures; `mkfs.ext4` actually formats the disk. `blkid` shows its unique filesystem ID (UUID). `/etc/fstab` records where to mount it at boot. “Mount” means making that disk's contents available at the directory `/var/opt/gitlab/git-data`.

### Install — all six storage VMs, NOT HAProxy

Use the **exact GitLab application version** agreed in §3. Example package syntax is `X.Y.Z-ee.0`; that is not a literal version. This guide uses the EE package, including for GitLab Free; do not mix arbitrary releases. Review the [Ubuntu installation instructions](https://docs.gitlab.com/install/package/ubuntu/) if your target release does not support Ubuntu24.04.

To install with Ansible, use the `gitlab_package` role and [installation playbook](../README.md#install-the-gitlab-package-on-storage-vms). That role replaces the manual package-install commands below; do not run both methods on the same node. The following commands remain the manual alternative.

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates openssh-server tzdata perl openssl
curl -fL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.deb.sh -o /home/ubuntu/gitlab-repo.sh
less /home/ubuntu/gitlab-repo.sh
sudo bash /home/ubuntu/gitlab-repo.sh
sudo mkdir -p /etc/gitlab
sudo touch /etc/gitlab/skip-auto-reconfigure
apt-cache madison gitlab-ee
read -r -p 'Exact matching package version, including -ee.0: ' PACKAGE_VERSION
sudo apt-get install -y "gitlab-ee=$PACKAGE_VERSION"
sudo apt-mark hold gitlab-ee
dpkg-query -W gitlab-ee
```

The skip file prevents an accidental all-in-one deployment. The hold prevents unattended version drift; plan patching rather than leaving it held forever.

The repository-install script adds GitLab's package source; it is separate from the optional certificate script. `less` lets you inspect it (press `q` to exit). `apt-cache madison` lists available versions; `dpkg-query` confirms what was installed. Installing the package puts the software on disk; `gitlab-ctl reconfigure` is the later command that applies your chosen configuration.

### First-time preparation: create the package's Linux user and folders

**Where:** all six storage VMs, not HAProxy. **Only for a fresh installation:** do not replace a working node's configuration with this temporary block.

The package runs its storage services under a Linux account named **`git`**. This is not your GitLab login and not a “Git server user” you create through the website. We need this account/group to exist before §10 can give the service permission to read its TLS private key.

“Bootstrap” here simply means **first-time preparation**. This guide uses a temporary local-only Gitaly configuration to let the package create its users and folders. It is our setup sequence, not a requirement that production Praefect must also run Gitaly.

On each fresh storage VM, run `sudo nano /etc/gitlab/gitlab.rb` and put in:

```ruby
roles(['gitaly_role'])
prometheus_monitoring['enable'] = false
gitlab_rails['auto_migrate'] = false
gitaly['configuration'] = { listen_addr: '', socket_path: '/var/opt/gitlab/gitaly/gitaly.socket' }
```

What that temporary configuration means:

- `roles(['gitaly_role'])`: prepare a Gitaly-only service configuration, not Rails or a complete GitLab website.
- `prometheus_monitoring['enable'] = false`: leave bundled monitoring off for this lab.
- `gitlab_rails['auto_migrate'] = false`: do not run Rails database migrations here.
- `listen_addr: ''`: do not open a plaintext TCP listener.
- `socket_path: ...gitaly.socket`: use a **Unix socket**, a local communication endpoint accessible only by processes on this VM with appropriate permissions.

**The socket is not a repository directory, a certificate, or an IP/port.** You do not create its file manually; the service creates it when starting. Another VM cannot connect to it over the network. It is `reconfigure` that creates the package users/folders—not the socket setting itself.

Run these commands one by one:

```bash
sudo chmod 600 /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure
sudo gitlab-ctl stop gitaly
id git
```

`chmod 600` restricts this sensitive configuration file to its owner. `reconfigure` applies the temporary setup. `stop gitaly` stops the temporary service while we install keys and write the real configuration. `id git` should now print the Linux account/group details; stop if the account is missing.

In §11 you **replace this temporary file**, not append to it. Gitaly VMs then use TLS9999 for network traffic; Praefect VMs run Praefect and disable Gitaly. The bootstrap socket is not how Praefect connects to another VM.

## 10. Issue and install certificates

**Why:** each storage server needs a certificate/key to identify itself, and the clients need the CA certificate to verify that identity. This is separate from the AWS RDS certificate you downloaded in §8.

**Prefer doing this by hand?** Follow [Manual TLS — root CA, handshake, bundles, and step-by-step OpenSSL commands](MANUAL-TLS-README.md). It replaces only the script-based generation below and produces the same filenames. Then return to “On each of the six storage VMs — NOT HAProxy” to install them. Choose one issuance method; do not generate a second CA over an existing one.

### Optional script method — on your laptop (skip if you used the manual guide)

Create a protected directory **outside the project/Git**, then invoke the supplied script by its actual path. `init-ca` creates your signing authority once; `issue` creates six server certificates. These commands are for first issuance, not for overwriting an existing CA:

```bash
umask 077
mkdir -p ~/gitaly-lab-private
chmod 700 ~/gitaly-lab-private
cd ~/gitaly-lab-private
bash /REPLACE_PROJECT_PATH/gitaly/make-certs.sh init-ca
bash /REPLACE_PROJECT_PATH/gitaly/make-certs.sh issue batch-01 praefect-lab.tyagi.fun
```

Keep the encrypted CA key and its passphrase backed up securely/offline. Signing prompts for that passphrase once per certificate. Certificates last 90 days; schedule renewal at day 60. The root lasts 3 years. Each Praefect certificate includes the common public endpoint and its own private name; each Gitaly certificate includes its private name.

### Upload files — on your laptop, after either issuance method

Copy only the target VM's certificate/key and the CA **certificate**, e.g.:

```bash
scp -i /path/to/lab-key.pem batch-01/gitaly-1.crt batch-01/gitaly-1.key ca/ca.crt ubuntu@REPLACE_GITALY1_PUBLIC_IP:/home/ubuntu/
```

Repeat for each node, substituting its own files/IP. Never send `ca/ca.key` to EC2, Kubernetes, or the other account.

### On each of the six storage VMs — NOT HAProxy

**Where:** SSH into the VM that received the files. The bootstrap step in §9 must have created its Linux `git` account. Set `NODE` to that VM's exact name. The example is for Gitaly-1; change it before using this block on another node:

**Before running the block:** this is first-install only; if `/etc/gitlab/ssl/current` already exists, stop and inspect instead of overwriting it. For later changes use the renewal guide.

```bash
NODE=gitaly-1
sudo install -d -m 0755 /etc/gitlab/ssl /etc/gitlab/trusted-certs
sudo install -d -o root -g git -m 0750 /etc/gitlab/ssl/batch-01
sudo install -o root -g git -m 0644 "/home/ubuntu/$NODE.crt" /etc/gitlab/ssl/batch-01/server.crt
sudo install -o root -g git -m 0640 "/home/ubuntu/$NODE.key" /etc/gitlab/ssl/batch-01/server.key
sudo ln -s /etc/gitlab/ssl/batch-01 /etc/gitlab/ssl/current
sudo install -m 0644 /home/ubuntu/ca.crt /etc/gitlab/trusted-certs/gitaly-lab-ca.crt
sudo install -m 0644 /home/ubuntu/ca.crt /usr/local/share/ca-certificates/gitaly-lab-ca.crt
sudo update-ca-certificates
```

Here, `install` means “copy a file and set its permissions,” not “download a package.” The key gets `root:git` ownership and mode0640 so the service can read it but other users cannot. `current` is a symbolic link (a filesystem pointer) to this certificate batch; the service configs use this stable path. The CA certificate goes into both the GitLab package trust directory and Ubuntu's trust directory. `update-ca-certificates` updates Ubuntu's trust store.

On **each Praefect VM** also download the RDS bundle from §8 and install it. Even though you already downloaded it on Praefect-1 for SQL setup, this puts it at the path the running Praefect service will use:

```bash
curl -fL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /home/ubuntu/rds-global-bundle.pem
sudo install -m 0644 /home/ubuntu/rds-global-bundle.pem /etc/gitlab/ssl/rds-global-bundle.pem
```

Once installed/verified, remove the staging **leaf key** from `/home/ubuntu` using its exact filename, e.g. `rm -- /home/ubuntu/gitaly-1.key`. The installed key remains; the staging copy is no longer needed.

## 11. Configure Gitaly, then Praefect

**Why this order:** Praefect needs working Gitaly endpoints and RDS before its cluster checks can pass. The `.rb` files are configuration, not scripts you run using `bash`. Paste their contents into `/etc/gitlab/gitlab.rb`, then apply them with `gitlab-ctl reconfigure`.

### Each Gitaly VM

Replace `/etc/gitlab/gitlab.rb` with [gitaly.rb](gitaly.rb), using `sudo nano`. Fill all placeholders; use its own storage name `gitaly-1`, `gitaly-2`, or `gitaly-3`. Use the SAME internal token on all three and the Shell callback secret chosen in §3. The callback URL is your GitLab application URL, not the Praefect endpoint.

The Rails-named settings do not host Rails on this VM. `internal_api_url` tells Gitaly where to call Rails; `gitaly['gitlab_secret']` authenticates those callbacks. If EKS is not installed yet, use the real planned URL and generated secret now. Callbacks cannot succeed until the application is deployed; never leave the literal secret placeholder in a running config.

```bash
sudo chmod 600 /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure
sudo gitlab-ctl status gitaly
sudo ss -lntp
```

`reconfigure` writes/applies the service configuration. `status gitaly` checks that the service is running; `ss -lntp` lists listening TCP ports. Expected: TLS9999 listening, no plaintext8075. If the GitLab HTTPS certificate uses another private CA, install that CA in BOTH trust locations from §10 and reconfigure/restart Gitaly too. Never use a TLS verification bypass.

### Each Praefect VM

Replace `/etc/gitlab/gitlab.rb` with [praefect.rb](praefect.rb). Fill endpoint/password/tokens identically on all three. `default` is the virtual storage name; `gitaly-1/2/3` are distinct physical storage names. Keep both migration switches false. Run `sudo chmod 600 /etc/gitlab/gitlab.rb` and `sudo gitlab-ctl reconfigure` on each. Schema-related errors before the next step are expected; unrelated failures are not.

### Create Praefect's tables — once, only on Praefect-1

In §8 you created an empty database. This migration command now creates/updates the tables Praefect needs **inside RDS**. It does not create a local database. `sudo -u git` runs the command as the service's Linux user; `-config` tells it which generated configuration to read. That configuration contains the RDS address, login and AWS CA path.

```bash
sudo -u git /opt/gitlab/embedded/bin/praefect -config /var/opt/gitlab/praefect/config.toml sql-migrate
```

### Start and check Praefect — on all three Praefect VMs

```bash
sudo gitlab-ctl restart praefect
sudo -u git /opt/gitlab/embedded/bin/praefect -config /var/opt/gitlab/praefect/config.toml sql-migrate-status
sudo -u git env SSL_CERT_DIR=/opt/gitlab/embedded/ssl/certs /opt/gitlab/embedded/bin/praefect -config /var/opt/gitlab/praefect/config.toml check
sudo gitlab-ctl status
sudo ss -lntp
```

The commands restart the service, list migration status, check the cluster, show service status, and list open ports. `SSL_CERT_DIR` tells this manually run check where to find the package's trusted certificates; it does not disable verification.

Expected: TLS3305, no plaintext2305, migrations applied and storage/database connectivity checks passing. Investigate with `sudo gitlab-ctl tail praefect` or `sudo gitlab-ctl tail gitaly`; Ctrl+C exits the log viewer. Don't share configs/logs containing tokens. [Praefect migration troubleshooting](https://docs.gitlab.com/administration/gitaly/praefect/troubleshooting/)

## 12. TCP load balancer — dedicated `haproxy-1` VM only

Skip this section only if you have separately planned/configured an NLB replacement. For the HAProxy lab described here, SSH to `haproxy-1` using its Elastic IP and run the following on that VM only:

```bash
sudo apt-get update
sudo apt-get install -y haproxy socat
sudo nano /etc/haproxy/haproxy.cfg
```

Replace the file with [haproxy.cfg](haproxy.cfg). Its three IPs match §6; edit if you changed them. Then:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager
echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock
```

`haproxy -c` checks the configuration before you use it; stop if it reports an error. `enable` makes the proxy start at boot. `restart` loads its configuration now. `socat` sends the `show stat` instruction through HAProxy's local admin socket to show backend status. That admin socket is a different local socket from Gitaly's bootstrap socket, and is not a public network port.

All three backend servers should be UP. This only proves TCP reachability, not database/replication health. The proxy has **no certificate/key**: encrypted bytes pass through to Praefect, which terminates TLS. Do not add HTTP mode, an HTTPS listener, backend `ssl`, or PROXY protocol. [HAProxy TCP mode](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/tcp/)

From your allowlisted laptop, in `~/gitaly-lab-private`:

```bash
openssl s_client -connect praefect-lab.tyagi.fun:443 -servername praefect-lab.tyagi.fun -alpn h2 -CAfile ca/ca.crt -verify_hostname praefect-lab.tyagi.fun -verify_return_error </dev/null
```

Expect successful certificate verification and ALPN `h2`. A browser or `curl https://...` is not a functional Praefect test. Repeat from the remote application network; laptop success does not prove pod routing works.

## 13. Connect the existing GitLab in the OTHER account

**Where:** the Kubernetes administrator's machine, not the storage VMs. **When:** after GitLab has been deployed. If EKS is still empty, stop after §12 for now; this section configures an existing Helm installation, not a complete first GitLab installation.

The external-storage values tell GitLab to use your Praefect endpoint instead of running its own bundled Gitaly. A Kubernetes Secret holds the shared token/CA data for the chart. It does not create or issue a certificate.

Give its administrator: endpoint `praefect-lab.tyagi.fun`, port443, TLS enabled, virtual storage `default`, the **external** token via a secure channel, and `ca.crt`. They do not need the internal Gitaly token, DB password, or any private key.

Before proceeding, confirm the client is disposable/empty (§3), that all its egress IPs are allowlisted, and that all six storage VMs can reach its GitLab HTTPS API. Git push needs this reverse callback path. Agree on the same GitLab version and Shell secret.

### Commands on the other account's Kubernetes admin machine

Substitute namespace/release names. The examples use both named `gitlab`. Put the external token in a local mode0600 file with **no trailing newline**, then create secrets:

```bash
kubectl -n gitlab create secret generic gitaly-lab-ca --from-file=gitaly-lab-ca.crt=/secure/path/ca.crt
kubectl -n gitlab create secret generic gitaly-lab-praefect-token --from-file=token=/secure/path/praefect-token
helm list -n gitlab
```

Merge [gitlab-external-gitaly.yaml](gitlab-external-gitaly.yaml) into a copy of their maintained full values file. Preserve existing custom CA entries and all unrelated values/secrets. **Helm replaces lists**, so do not blindly overlay the sample's `customCAs` list. The installation's `global.shell.authToken` must reference the same secret value you used on Gitaly. For an existing installation preserve that value; for your new installation supply the value generated in §3 during its initial setup.

Render/review, then upgrade using the **same currently installed chart version**, not latest:

```bash
helm template gitlab gitlab/gitlab -n gitlab --version REPLACE_CURRENT_CHART_VERSION -f /secure/path/merged-values.yaml > /secure/path/rendered.yaml
helm upgrade gitlab gitlab/gitlab -n gitlab --version REPLACE_CURRENT_CHART_VERSION -f /secure/path/merged-values.yaml --timeout 15m
kubectl -n gitlab get pods
kubectl -n gitlab exec -it REPLACE_TOOLBOX_POD -- gitlab-rake gitlab:gitaly:check
```

Rendered manifests may contain secrets: protect/delete that local file after review. Ensure client pods have rolled to load the new CA/config; complete any required controlled rollouts. Existing image-pull/Helm-repository access remains the remote administrator's responsibility. [GitLab chart external Gitaly integration](https://docs.gitlab.com/charts/advanced/external-gitaly/)

`helm template` previews the Kubernetes objects without deploying them. `helm upgrade` applies the reviewed settings. `kubectl get pods` shows the running components. The last command runs GitLab's storage connectivity check inside the Toolbox pod. Only proceed to failure testing after this and a real push work.

## 14. Acceptance tests — do not stop at a green load balancer

**Why:** a running process or open port is not enough. These tests prove that the application can write/read repositories and continue serving new requests when one backend is unavailable. Run them only on dummy data, one failure at a time. If GitLab is not deployed yet, defer this section.

1. Create a new throwaway project in the connected GitLab. Clone, commit, push, clone into another directory, and compare the commit IDs. Repeat using Git SSH if that client supports it.
2. Run `gitlab:gitaly:check` above and `praefect check` from §11. On Praefect-1, inspect replication health:

   ```bash
   sudo -u git /opt/gitlab/embedded/bin/praefect -config /var/opt/gitlab/praefect/config.toml dataloss -virtual-storage default -partially-unavailable
   ```

   Wait until no missing/outdated replicas are reported before testing failures. The command is diagnostic; **never run `accept-dataloss` as a troubleshooting shortcut**. [GitLab recovery diagnostics](https://docs.gitlab.com/administration/gitaly/praefect/recovery/)
3. On Praefect-2, stop ONLY `praefect` (`sudo gitlab-ctl stop praefect`). Confirm the HAProxy backend goes DOWN and new clone/push attempts succeed through other nodes; in-flight operations can fail. Restart it and recheck health.
4. With all nodes healthy again, stop ONLY Gitaly-3's `gitaly` service. Test operations, restart it, and wait for full replica recovery before touching any other node.
5. Do not stop `haproxy-1` and expect uninterrupted access: it is the only entry point. Praefect-1 no longer hosts HAProxy and can be tested one at a time like the other Praefect nodes. Do not test two simultaneous Gitaly failures. Document observed retry/failover behavior, not just “HA works.”
6. Rehearse [certificate renewal](TLS-RENEWAL.md) while this is a disposable lab. Keep a reminder and monitor expiration; the script does not schedule renewal for you.

### Quick troubleshooting

| Symptom | Check first |
|---|---|
| Public endpoint timeout | Actual pod egress IP vs SG allowlist; EIP/DNS; HAProxy443 listener; public route |
| Internal endpoint timeout | Private exact-host DNS zone resolves to `10.70.0.5`; SG443 from Gitaly/Praefect |
| Unknown CA / hostname mismatch | Client trust store, SAN, clock, correct certificate on all three Praefects |
| Unauthenticated RPC | External token at clients/Praefect; internal token at Praefect/Gitaly; no newline |
| Clone works but push fails | Shell secret, GitLab HTTPS callback URL, remote inbound allowlist, callback CA trust |
| RDS errors | Private route, SG5432, AWS CA bundle, password, migrations, supported PG version |
| One replica stale | Gitaly-to-Gitaly9999 rules, disk space, matching physical storage names, service logs |

## 15. Cleanup and what this POC does NOT prove

**Where:** AWS Console when you have finished the lab. **Why:** resources can keep billing even if you are not using GitLab. Review every selected resource name before deleting anything.

Use only dummy repositories. Before deleting resources, export anything you want to keep. Replicas and uncoordinated EBS snapshots are not a tested GitLab backup/restore strategy.

For cleanup, first disconnect the disposable GitLab client from this storage. In the Console remove **only lab resources**: seven instances, their unneeded EBS volumes/snapshots, RDS (decide whether to retain a final snapshot), Elastic IP, the lab DNS records/private zones, SGs and VPC resources. Retained snapshots, volumes, IPs, and zones can continue billing. Do not delete your public `tyagi.fun` zone or unrelated client resources. Stopping is not permanent cleanup; RDS stopped instances can automatically restart.

Before production, revisit private cross-account connectivity, managed/HA TCP ingress, Multi-AZ database, backups and restore drills, monitoring, certificate automation, controlled upgrades and capacity testing. Scaling instance sizes alone does not turn this lab into a production deployment.

Files: [Manual certificates](MANUAL-TLS-README.md) · [TLS renewal](TLS-RENEWAL.md) · [Gitaly config](gitaly.rb) · [Praefect config](praefect.rb) · [HAProxy config](haproxy.cfg) · [GitLab Helm values](gitlab-external-gitaly.yaml) · [optional certificate script](make-certs.sh).
