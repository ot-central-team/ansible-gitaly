# Internal TLS certificates

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
`inventory/lab/group_vars/praefect/vars.yml` before issuing certificates. The
current `[haproxy]` group is empty, so this playbook does not configure or issue
a frontend certificate for HAProxy.

Inspect a node certificate after the playbook completes:

```bash
sudo openssl x509 -in /etc/gitlab/ssl/server.crt \
  -noout -subject -issuer -dates -ext subjectAltName
sudo openssl verify \
  -CAfile /etc/gitlab/trusted-certs/repo-data-internal-ca.crt \
  /etc/gitlab/ssl/server.crt
```

To force a new leaf certificate, use
`-e tls_certificate_force_renew=true`. This only replaces the certificate
files; it does not reload Praefect or Gitaly. Do not use it for an active TLS
service until the later rolling-renewal procedure is in place.

Select each operation using `ansible.builtin.import_role` with `name: tls`
and `tasks_from: ca_generation.yml` or `tasks_from: distribution_tls.yml`.
CA generation runs on the bastion; distribution runs on Gitaly/Praefect and
delegates signing to the bastion. There is no default `tasks/main.yml`.

`tasks/renewal_tls.yml` is an explicit not-implemented entry point migrated
from the empty renewal role. It fails with an explanation and performs no
renewal or service restart. No renewal timer is installed.
