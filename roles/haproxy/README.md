# HAProxy on the bastion

`playbooks/setup_haproxy.yml` targets `[bastion]`. It is separate from cluster
bootstrap. The empty `[haproxy]` inventory group is not used by this playbook;
put settings in `inventory/lab/group_vars/bastion/vars.yml`.

Traffic flows from clients through public TLS on HAProxy port 443, then through
a separate verified TLS connection to each Praefect node on port 3305. Both
legs negotiate ALPN h2, but HAProxy stays in TCP mode to preserve Gitaly
sidechannels. No GitLab token is stored in HAProxy; Praefect authenticates
forwarded application requests using its external token.

## Inputs

Complete cluster setup, migration and Praefect health checks first. Provide a
public certificate covering the chosen public DNS hostname and its matching
unencrypted private key. The full chain must start with the leaf certificate.
Place these existing files securely on the bastion (not in Git). On the bastion:

```bash
sudo install -d -m 0700 /etc/ansible/pki/haproxy
sudo sh -c 'umask 077; cat /PATH/TO/fullchain.pem /PATH/TO/privkey.pem > /etc/ansible/pki/haproxy/public.pem'
```

Replace the source paths. The role does not generate or renew this public
certificate. It copies the supplied PEM on changes and validates before reload.
The internal CA public certificate is read from `tls_ca_certificate_path` on
the bastion. The CA private key is not copied into HAProxy's certificate directory.

Set bastion variables:

```yaml
haproxy_public_hostname: praefect.example.com # replace with your real domain
haproxy_public_pem_source: /etc/ansible/pki/haproxy/public.pem
haproxy_allowed_client_sources:
  - "{{ cluster_cidr }}"
  # Add approved external clients, for example an office public egress IP /32.
```

Backends default to the `[praefect]` inventory hostnames; these must resolve on
the bastion and appear in each backend certificate's DNS SAN. The role checks
backend TLS before deployment; unreachable/untrusted backends stop the run.
It supports multiple Praefect nodes and uses leastconn balancing with DNS
refresh and TLS handshake health checks. These checks are not database or
repository-operation checks.

## Network and deployment

- Public DNS must point at the bastion's public address (prefer an Elastic IP).
  Public access requires appropriate subnet routing to an internet gateway.
- Bastion security group: TCP 443 inbound from approved client sources, and
  outbound TCP 3305 to Praefect. Preserve existing SSH administration access.
- Praefect security group: TCP 3305 inbound from the bastion security group;
  Praefect UFW must also allow the bastion private address or approved subnet.
- This role adds only UFW allow rules. It does not enable UFW, alter default
  policies, or remove existing rules. When UFW is inactive, AWS security groups
  must still enforce your approved sources. Removing a source from variables
  does not delete a previous allowance automatically.

Run on the Ansible controller:

```bash
ansible-playbook playbooks/setup_haproxy.yml --syntax-check --ask-vault-pass
ansible-playbook playbooks/setup_haproxy.yml --ask-vault-pass
```

The role owns `/etc/haproxy/haproxy.cfg` and backs up an existing config before
replacing it. Do not use it unmodified on a bastion already serving unrelated
HAProxy frontends. Its handlers reload validated changes; they do not reconfigure
GitLab. A single bastion remains a single point of failure.

From an allowed client, using your actual public hostname:

```bash
openssl s_client -connect praefect.example.com:443 \
  -servername praefect.example.com -verify_hostname praefect.example.com \
  -CApath /etc/ssl/certs -verify_return_error -alpn h2 -brief </dev/null
```

Expected: `Verification: OK`. This verifies the frontend TLS connection only.
On Praefect run `sudo gitlab-ctl praefect check` for backend checks. An actual
GitLab client operation is required to verify the complete proxy path.
Applications use `tls://praefect.example.com:443`, the external Praefect token,
and virtual storage `default`. This endpoint is not an HTTP website.

References: [GitLab TCP load-balancer requirements](https://docs.gitlab.com/administration/gitaly/praefect/configure/),
[HAProxy TLS configuration](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/security/ssl-tls/basics-enable-tls/).
