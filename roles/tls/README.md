# Internal TLS certificates

Set `cluster_rpc_tls_enabled: true` in `group_vars/all` before these workflows.
It enables TLS for both Gitaly and Praefect. With `false`, cluster bootstrap skips
CA creation/distribution and `renew_tls.yml` skips all node renewal tasks.
Timer installation requires TLS mode. Stop an existing timer when disabling TLS.


`roles/tls/tasks/ca_generation.yml` creates the encrypted root CA key and certificate on the
bastion. Run it once with `playbooks/configure_cluster.yml --tags ca`. The task file
`roles/tls/tasks/distribution_tls.yml` makes a private server key and CSR on each target
VM, signs the CSR on the bastion using the existing CA, and installs the
resulting certificate and public CA certificate. Private server keys never
leave their VMs; the CA private key never leaves the bastion. Public CSRs and
certificates are temporarily staged under the ignored `.ansible-tls/` directory
on the Ansible controller.

The current default leaf lifetime is 365 days. The role installs certificate files and updates system CA trust:
it does not edit `gitlab.rb`, activate TLS listeners, run `gitlab-ctl
reconfigure`, or restart services. TLS activation and a monitored rolling
renewal plan must be completed separately before production traffic uses TLS.

Before running the playbook, add a unique passphrase of at least 16 characters
to the vaulted `inventory/lab/group_vars/bastion/vault.yml` file:

```yaml
tls_ca_privatekey_passphrase: "use-a-long-unique-secret"
```

Edit the vaulted file with `ansible-vault edit`; do not put the passphrase in a
plain-text vars file or commit it. The file mode for the CA key is `0600`, and
the CA directory is `0700` on the bastion.

Install the collection and check both playbooks:

```bash
ansible-galaxy collection install -r collections/requirements.yml
ansible-playbook playbooks/configure_cluster.yml --tags ca --syntax-check --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags certificates --syntax-check --ask-vault-pass
```

Create the CA once, then issue certificates for the current nodes:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags ca --ask-vault-pass
ansible-playbook playbooks/configure_cluster.yml --tags certificates --ask-vault-pass
```

When adding a node later, add it to the inventory and run only that host, for
example:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags certificates \
  --limit gitaly-3.repo-data.internal --ask-vault-pass
```

The certificate playbook fetches the existing public CA certificate from the
bastion; it does not create or renew the CA.

The inventory hostname is placed in each certificate's Subject Alternative
Name. For Praefect, add the DNS name clients actually use (for example, the
Praefect load-balancer name) to `tls_extra_dns_names` in
`inventory/lab/group_vars/praefect/vars.yml` before issuing certificates. Use TCP passthrough on the NLB; see [transport modes](../../TRANSPORT.md).
The inventory uses `praefect_external_hostname` for the client-facing SAN.
Do not overwrite bootstrap certificates.

Inspect a node certificate after the playbook completes:

```bash
sudo openssl x509 -in /etc/gitlab/ssl/server.crt \
  -noout -subject -issuer -dates -ext subjectAltName
sudo openssl verify \
  -CAfile /etc/gitlab/trusted-certs/repo-data-internal-ca.crt \
  /etc/gitlab/ssl/server.crt
```

Bootstrap preserves existing private keys, CSRs and certificates. Creation tasks
run only for missing material; existing cryptographic files are not reconciled
when names, SANs, passphrases or lifetimes change. Node CSRs are now retained.
On older deployments where the role deleted a CSR, an existing server certificate
is sufficient to skip issuance; the missing CSR is not recreated on a rerun.
Missing private keys alongside existing public material, differing archived CSRs,
missing deployed certificates with an existing signed archive, and changed CA
trust files cause a clear failure requiring explicit recovery or rotation.

`tls_certificate_force_renew=true` is rejected by bootstrap. Expired certificates
are also preserved, not automatically renewed. Plan renewal separately before
expiry. Staging copies and permissions can still be maintained by Ansible;
this preservation policy concerns cryptographic file contents.

Select each operation using `ansible.builtin.import_role` with `name: tls`
and `tasks_from: ca_generation.yml` or `tasks_from: distribution_tls.yml`.
CA generation runs on the bastion; distribution runs on Gitaly/Praefect and
delegates signing to the bastion. There is no default `tasks/main.yml`.

`tasks/renewal_tls.yml` provides explicit leaf renewal with preserved private
keys, staged validation, rollback and optional Praefect NLB draining. See
[RENEWAL.md](RENEWAL.md) for the first NLB SAN update, manual commands and the
optional daily timer that renews certificates at 30 days old. CA rotation is
not included. No timer is installed by cluster bootstrap.
