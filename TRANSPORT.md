# One role set, two RPC transport modes

Set `cluster_rpc_tls_enabled` to the YAML boolean `true` or `false` in
`inventory/lab/group_vars/all/vars.yml`. It applies to Gitaly, Praefect and the
bastion. Remove the old `gitaly_enable_tls` and `praefect_enable_tls` variables
from all inventory/extra-vars sources. Mixed or per-host modes are rejected.

| Setting | Plaintext (`false`) | TLS (`true`) |
|---|---|---|
| Praefect RPC listener | 2305 | 3305 |
| Gitaly RPC listener | 8075 | 9999 |
| Praefect backend scheme | `tcp://` | `tls://` |
| NLB listener protocol | TCP | TCP (TLS passthrough) |
| Example NLB frontend port | 443 | 443 |
| NLB target protocol/port | TCP / 2305 | TCP / 3305 |
| Helm external `tlsEnabled` | `false` | `true` |
| Internal CA required in pods | No | Yes |
| Praefect database TLS | `verify-full` | `verify-full` |

Port 443 does not imply encryption. Do not configure an NLB TLS-termination
listener for this passthrough design. Configure security groups and TCP target
health checks for the selected ports. UFW allows the selected port, but this
role does not remove historical rules; review/remove obsolete allowances and
use private CIDRs instead of the lab's `0.0.0.0/0` before production.

## Fresh deployment

1. Choose the shared mode and set `praefect_external_hostname` to the DNS name
   used by EKS clients. It is included in Praefect certificates' DNS SANs.
2. Supply database credentials/tokens as documented in README. In TLS mode,
   also supply the vaulted CA passphrase. Plaintext mode needs no CA passphrase.
3. Run the same playbook in either mode:

```bash
ansible-playbook playbooks/configure_cluster.yml --ask-vault-pass
```

4. Run the printed `sql-migrate` command on **one** Praefect node. Verify with
   `sql-migrate-status` and `sudo gitlab-ctl praefect check` on each Praefect node.
   Migrations are intentionally manual and read the same generated database
   TLS settings. RPC mode never disables RDS encryption.
5. Configure NLB targets and Helm consistently with the table above.

## EKS configuration

Plaintext: use your customized `eks/gitlab-values.yaml` alone. Its external
Gitaly entry actually points at Praefect through the NLB. Keep `tlsEnabled: false`.

TLS: copy **only the public CA certificate** from the bastion's
`/etc/ansible/pki/repo-data/ca.crt` to `eks/local/repo-data-internal-ca.crt`.
Never copy CA or server private keys to EKS. Create/update the trust Secret:

```bash
kubectl -n gitlab create secret generic repo-data-internal-ca \
  --from-file=repo-data-internal-ca.crt=eks/local/repo-data-internal-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

Copy `eks/gitlab-values-tls.yaml` to `eks/local/` and customize its hostname,
frontend port and virtual storage name to match your deployment. Helm lists
replace earlier lists: preserve every required custom CA and external storage.
Apply it **after** your customized base file:

```bash
helm upgrade --install gitlab gitlab/gitlab --namespace gitlab --version 10.4.1 \
  -f eks/local/gitlab-values.yaml -f eks/local/gitlab-values-tls.yaml
```

Use the same two files for template/dry-run validation and subsequent upgrades.
The example chart version matches this repository's GitLab 19.4.1 pin.
This private RPC TLS setting is independent of public ALB HTTPS, Redis TLS and RDS TLS.

## Changing mode on an existing cluster

This is a maintenance-window operation, not a zero-downtime toggle. Stop/drain
application and CI Git traffic first. Set the shared variable, rerun the cluster
playbook, update AWS firewall/NLB target settings, and redeploy Helm with the
matching files. For TLS-to-plaintext, omit the TLS override and verify the
rendered external endpoint has `tlsEnabled: false`; do not use `--reuse-values`
to retain an old TLS value. Stop/disable the optional controller renewal timer:

```bash
sudo systemctl disable --now gitlab-tls-renewal.timer
```

Existing certificate/key files are preserved when disabling TLS. Bootstrap
never silently renews old certificates. Before enabling TLS on existing nodes,
inspect expiry and SANs, including `praefect_external_hostname`. If existing
material is expired or lacks a required SAN, use the documented renewal workflow
on an already TLS-configured service during maintenance, then verify before
restoring traffic. Never delete keys to force bootstrap issuance.

## Verification

Both modes: check service status, migration status, `gitlab-ctl praefect check`,
then run `gitlab-rake gitlab:gitaly:check` in Toolbox and perform a real repository
create/push/clone test. A TCP health check alone does not validate Git operations.

TLS only (from a network that can reach the internal NLB):

```bash
openssl s_client -connect nlb.tyagi.fun:443 -servername nlb.tyagi.fun \
  -verify_hostname nlb.tyagi.fun -CAfile eks/local/repo-data-internal-ca.crt \
  -verify_return_error -alpn h2 -brief </dev/null
```

Replace the example DNS/port everywhere consistently. Do not run this TLS
handshake check against the plaintext endpoint. Renewal skips nodes when shared
TLS is disabled; the optional timer targets Praefect only. Gitaly renewal still
requires the separate maintenance workflow in `roles/tls/RENEWAL.md`.
