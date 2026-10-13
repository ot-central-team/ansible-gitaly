# Renew existing private-CA certificates

The renewal implementation has just two task files:

- `tasks/renewal_tls.yml`: all renewal, validation, activation and rollback steps.
- `tasks/schedule_renewal.yml`: controller timer setup, including both systemd units.

There are no separate renewal helper scripts or template files. The two small
playbooks are the commands used to run these tasks.

Use the existing TLS role through `playbooks/renew_tls.yml`. Bootstrap still
preserves certificates. Renewal never creates or replaces a private key or CA.
It is only for the private-CA leaf files already used by the running services;
externally issued public certificates are not renewed by this workflow.

The workflow runs one node at a time and renews when:

- the desired DNS names differ from the certificate;
- the certificate reaches `tls_renew_interval_days` (default 30 days);
- expiry is within the same `tls_renew_interval_days` buffer (default 30 days); or
- `tls_renew_force=true` is explicitly passed.

New certificates retain the configured lifetime (365 days by default). Renewing
every 30 days does not mean issuing certificates that expire after 30 days.
The CA must remain valid for the entire new leaf lifetime. This is planned
renewal, not an expired-cluster recovery tool: cluster health must pass first.
Requires Python 3.11+ on the VMs (Ubuntu 24.04), the existing crypto dependencies,
working GitLab services and database migrations, and passwordless Ansible sudo.

## Current lab: add the NLB name

Praefect group vars already contain:

```yaml
tls_extra_dns_names:
  - loadbalancer-e2f43192ead7f879.elb.ap-south-1.amazonaws.com
```

For the initial lab, while application traffic is stopped, run on the controller:

```bash
ansible-playbook playbooks/renew_tls.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/renew_tls.yml --limit praefect --ask-vault-pass \
  -e tls_renew_maintenance_window=true
```

This updates Praefect CSRs/certificates and restarts Praefect serially. It does
not touch Gitaly or the CA. The explicit maintenance flag bypasses NLB draining;
use it only during an agreed outage/maintenance window. Re-running immediately
skips issuance when names and age already meet policy.

Now test from the bastion WITHOUT the certificate-name override:

```bash
sudo /usr/local/bin/grpc-health-probe \
  -addr=loadbalancer-e2f43192ead7f879.elb.ap-south-1.amazonaws.com:3305 \
  -tls -tls-ca-cert=/etc/ansible/pki/repo-data/ca.crt \
  -connect-timeout=10s -rpc-timeout=10s
```

Expect SERVING. Rails must trust the same public CA certificate, use this
`tls://...:3305` endpoint, virtual storage `default` and the external token.
This is different from the custom-public-certificate example in NLB-SETUP.md.

## Live Praefect: configure NLB draining before scheduling

Set these in `inventory/lab/group_vars/praefect/vars.yml`:

```yaml
tls_renew_nlb_target_group_arn: arn:aws:elasticloadbalancing:REGION:ACCOUNT:targetgroup/NAME/ID
```

Set each VM's registered EC2 instance ID in its own host_vars file:

```yaml
# inventory/lab/host_vars/praefect-1.internal.yml
tls_renew_nlb_target_id: i-REPLACE_WITH_THIS_PRAEFECT_INSTANCE
```

Region is derived from the ARN, and the Praefect target port is 3305.
Use the exact target-group ARN and IDs shown in EC2 Target Groups. This workflow
handles a single instance target group per node; do not use it if the service
receives traffic through other target groups or direct clients that also need
draining. Ensure the IDs correspond to the actual inventory nodes.

The AWS CLI must be installed on the controller. Its execution user needs
`elasticloadbalancing:DescribeTargetHealth`, `DeregisterTargets`, `RegisterTargets`
for this target group (scope IAM permissions appropriately). Prefer an instance
role on the controller, not static access keys in inventory.

```bash
ansible-playbook playbooks/renew_tls.yml --limit praefect --ask-vault-pass
```

The role requires this target to be healthy and at least one other healthy
target, waits for deregistration, installs the validated certificate, restarts
Praefect, verifies the served certificate/h2 and full Praefect checks, registers
the target and waits for AWS health. It refuses to drain the last healthy target.
Configure cross-zone routing and backend capacity so remaining targets can serve
clients. Long-running RPCs may still be interrupted when the drain deadline ends;
this is not a zero-downtime guarantee.

Activation failures attempt restoration from `server.crt.pre-renewal`, restart
and health checks. Only a healthy rollback is returned to NLB. The rollout then
fails and stops; inspect errors before retrying. If rollback fails, investigate
service health and target registration before manually restoring traffic.
Successful renewals retain backed-up CSR/certificate archives on the bastion.
Private keys never travel to the controller or signing bastion.

Do not run concurrent manual and scheduled renewals. Stop the timer and wait for
any active service to finish before a manual run. Check mode is rejected.

## Optional unattended schedule on the Ansible controller

First complete a successful manual drained renewal. Configure working SSH keys,
known_hosts, passwordless sudo and AWS credentials for the scheduler user.
An unattended run cannot answer Vault prompts. Store your existing Vault unlock
password outside Git with permissions 0600; it is not a new CA or Vault password:

```bash
install -d -m 0700 "$HOME/.config/ansible"
# Use an editor so the password does not appear in shell history.
(umask 077; touch "$HOME/.config/ansible/vault-password")
nano "$HOME/.config/ansible/vault-password"
chmod 0600 "$HOME/.config/ansible/vault-password"
command -v ansible-playbook
```

For the usual Ubuntu controller, from the repository root (adjust paths/user):

```bash
ansible-playbook playbooks/setup_tls_renewal_timer.yml --ask-vault-pass \
  -e tls_renew_schedule_user=ubuntu \
  -e tls_renew_schedule_vault_password_file=/home/ubuntu/.config/ansible/vault-password
```

Repository location and the Ansible executable path are derived from the
playbook location and current Ansible Python environment. The timer always
targets Praefect.

The timer checks daily at 03:00 controller-local time plus up to 15 minutes of
jitter. Only due certificates are renewed, so the default interval is roughly
30 days. A persistent timer catches up after downtime. Installation enables the
timer; a missed calendar run can trigger promptly. It forces maintenance bypass
and forced renewal OFF. It targets Praefect only, and will fail safely if NLB
settings or redundant healthy targets are missing. Failure is visible in systemd;
connect it to your monitoring/alerts rather than assuming renewal always succeeds.

```bash
sudo systemctl list-timers gitlab-tls-renewal.timer
sudo systemctl status gitlab-tls-renewal.service
sudo journalctl -u gitlab-tls-renewal.service -n 100 --no-pager
# Disable future scheduled runs (does not interrupt an active renewal):
sudo systemctl disable --now gitlab-tls-renewal.timer
```

To change cadence, set `tls_renew_interval_days` in Praefect group vars. Keep
certificate lifetime longer than the interval and the expiry buffer. Vault
passwords/private keys stay outside Git. The timer is installed only on the
controller, never on every storage VM.

## Gitaly renewal

The same signing/validation/rollback flow supports Gitaly, but automatic live
Gitaly draining is not implemented. Plan a maintenance window, stop application
traffic and verify replication first, then:

```bash
ansible-playbook playbooks/renew_tls.yml --limit gitaly --ask-vault-pass \
  -e tls_renew_maintenance_window=true
```

Each Gitaly restarts separately and Praefect checks run between nodes. Do not
include Gitaly in the unattended Praefect timer. CA expiry/rotation is a separate
operation and is deliberately not performed here.
