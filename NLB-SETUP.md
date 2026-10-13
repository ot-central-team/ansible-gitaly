# Internal NLB for Praefect — nlb.tyagi.fun

This replaces the repository endpoint with `tls://nlb.tyagi.fun:443`.
It is for GitLab application clients, not the GitLab website or browser UI.
These instructions configure AWS manually; no AWS resources are created by Ansible.

```text
Rails / Sidekiq / Toolbox / bastion (VPC-connected)
  → nlb.tyagi.fun:443 → Internal NLB (TCP 443)
  → Praefect (TLS 3305) → Gitaly (TLS 9999)
```

Use TCP passthrough. GitLab requires a TCP load balancer because its repository
protocol uses sidechannels. This also preserves ALPN. TLS terminates on Praefect,
so install your existing public certificate there, not in ACM/on the NLB.
Do not select an HTTP/gRPC application load balancer for this endpoint.

## 1. Prepare the public certificate on every Praefect VM

Your certificate must cover `nlb.tyagi.fun` and be issued by a publicly trusted CA.
Prepare these files outside Git (copy them securely to each Praefect VM):

- `certificate.crt`: leaf certificate for nlb.tyagi.fun.
- `ca_bundle.crt`: issuer's intermediate certificate chain.
- `private.key`: matching private key, not the internal CA key.

On each Praefect VM, from the directory containing those files:

```bash
openssl x509 -in certificate.crt -noout -checkhost nlb.tyagi.fun
openssl x509 -in certificate.crt -noout -checkend 86400
openssl verify -purpose sslserver -verify_hostname nlb.tyagi.fun \
  -CAfile /etc/ssl/certs/ca-certificates.crt \
  -untrusted ca_bundle.crt certificate.crt

# These two hashes must match. Stop if they do not.
openssl x509 -in certificate.crt -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum
openssl pkey -in private.key -pubout -outform DER | sha256sum

cat certificate.crt ca_bundle.crt > fullchain.pem
sudo install -d -o root -g git -m 0750 /etc/gitlab/ssl/nlb
sudo install -o root -g git -m 0640 fullchain.pem /etc/gitlab/ssl/nlb/fullchain.pem
sudo install -o root -g git -m 0640 private.key /etc/gitlab/ssl/nlb/private.key
```

Check all validation commands succeed before installing. Praefect needs a key
it can read without an interactive passphrase prompt. Protect it with the file
permissions above. Keep these files separate from `server.key`/`server.crt` so
the existing private-CA bootstrap does not overwrite them.

In `inventory/lab/group_vars/praefect/vars.yml`, add:

```yaml
praefect_tls_certificate_path: /etc/gitlab/ssl/nlb/fullchain.pem
praefect_tls_privatekey_path: /etc/gitlab/ssl/nlb/private.key
```

Then from the Ansible controller:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags praefect --ask-vault-pass
```

The path change triggers reconfiguration. This can interrupt connections; for
an existing live service, schedule the change and drain one node at a time.
The private CA still authenticates Gitaly; do not delete it or change its key.
No change to Gitaly certificates, tokens or database migrations is required.
The public certificate does not need to cover each private Praefect hostname
when clients always verify the shared `nlb.tyagi.fun` name.

Imported public certificates do not renew through this repository. Track expiry,
replace the full chain/key before expiry, and restart Praefect one node at a time
after validation. The role currently reconfigures only when gitlab.rb changes;
a certificate-only replacement needs an explicit service restart.

## 2. Create security groups

In the same VPC as Praefect, create an NLB security group:

- Inbound TCP 443: approved EKS client security groups and bastion security group
  (or their actual source CIDRs where group references are unsuitable).
- Outbound TCP 3305: Praefect security group, for traffic and health checks.
- On Praefect's security group: inbound TCP 3305 from the NLB security group.

Associate the security group when creating NLB. Keep Praefect's 3305 and Gitaly's
9999 private. Verify UFW on Praefect also allows 3305 from the NLB subnet CIDRs.
With client-IP preservation disabled below, it sees the NLB source addresses.
Your `common` role's allowed source range must include those subnets; AWS SGs
remain the restriction to the NLB. Do not open all ports to the internet.

## 3. Create the target group and NLB

EC2 → Target groups → Create target group:

| Setting | Value |
|---|---|
| Target type | Instances |
| Name | praefect-tcp-3305 |
| Protocol / port | TCP / 3305 |
| VPC | Praefect's VPC |
| Health check | TCP, traffic port (3305) |
| Registered targets | All configured, healthy Praefect EC2 instances only |

In target group attributes, explicitly **disable client IP preservation** and
leave **Proxy Protocol v2 disabled**. Praefect is not configured to parse it.

EC2 → Load balancers → Create → Network Load Balancer:

| Setting | Value |
|---|---|
| Name | praefect-internal |
| Scheme | Internal |
| IP type | IPv4 |
| VPC | Same as Praefect |
| Subnets | At least two AZs; include the target AZs |
| Security group | NLB group created above |
| Listener | TCP 443 → praefect-tcp-3305 |
| Certificate on NLB | None: TCP passes the encrypted connection through |

Enable cross-zone load balancing so enabled NLB zones can reach healthy
Praefect targets in other enabled zones. Wait for NLB to become Active and
all intended targets Healthy. Multiple NLB zones do not provide backend HA if
you only have one Praefect. TCP health checks check a port, not database health.

## 4. Add DNS in Hostinger

Create this DNS record:

| Type | Name | Target |
|---|---|---|
| CNAME | nlb | The exact AWS NLB DNS name from its Details page |

Use the DNS name without `https://`, a port, or a path. Do not pin the name to
one NLB IP. Remove a conflicting record for this same name if present.
A public DNS record for an internal NLB resolves to private addresses; it does
not make it publicly reachable. Test from the bastion, EKS, or a VPN-connected
computer. A normal home internet connection cannot reach an internal NLB.

## 5. Test from the bastion or another VPC-connected client

```bash
getent ahostsv4 nlb.tyagi.fun
nc -vz -w 5 nlb.tyagi.fun 443

# Public CA bundle: validates certificate chain, domain and TLS handshake.
timeout 15 openssl s_client \
  -connect nlb.tyagi.fun:443 \
  -servername nlb.tyagi.fun \
  -verify_hostname nlb.tyagi.fun \
  -CAfile /etc/ssl/certs/ca-certificates.crt \
  -verify_return_error -alpn h2 -brief -no_ign_eof </dev/null

# With grpc-health-probe already installed:
grpc-health-probe \
  -addr=nlb.tyagi.fun:443 \
  -tls -tls-server-name=nlb.tyagi.fun \
  -connect-timeout=10s -rpc-timeout=10s
```

Expect TLS `Verification: OK` and gRPC `status: SERVING`. If OpenSSL waits for
connection closure, use the gRPC probe to confirm a completed application RPC;
a timeout alone is not a successful test. Do not use insecure verification flags.
Repeat for each target before relying on the endpoint; a probe through NLB only
checks the backend selected for that connection.

On each Praefect VM, also run:

```bash
sudo gitlab-ctl praefect check
```

This checks migrations, database and Gitaly connectivity. A gRPC health response
is not a repository operation or a validation of the external token. After
connecting Rails, test actual clone, push and fetch operations too.

## 6. Connect GitLab and retire the previous proxy

`eks/gitlab-values.yaml` now uses `nlb.tyagi.fun`, port 443 and TLS. Applications
use the same `praefect_external_token` and virtual storage name `default`.
They trust the public certificate through their normal public CA bundle.

Repository cleanup does not stop or uninstall a service already running on a VM.
Only after NLB tests and application cutover succeed, on the old proxy/bastion:

```bash
sudo systemctl disable --now haproxy
```

Retire its old DNS and dedicated firewall/SG allowances after confirming there
are no remaining clients. Keep bastion SSH, CA material and database access.

## References

- [GitLab Praefect load balancing and TLS](https://docs.gitlab.com/administration/gitaly/praefect/configure/)
- [AWS NLB listeners and TCP passthrough](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-listeners.html)
- [NLB security groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-security-groups.html)
- [Target group attributes and client IP preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html)
