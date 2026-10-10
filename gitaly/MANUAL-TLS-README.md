# TLS certificates, explained simply

This guide explains and manually creates the certificates used by the Gitaly lab. Follow the main [Gitaly setup guide](README.md) for installing them on the VMs.

> **For your first lab:** create certificates on your trusted laptop, not on a VM and never on HAProxy. Use Bash and OpenSSL 3.x. Keep this work folder outside Git and cloud-synced folders.

## The short version

TLS lets each service prove its identity and encrypt its network connection. It does **not** replace the Praefect/Gitaly tokens.

We make one private issuer called a **CA**, then it signs six server certificates:

```text
Your CA signs:  Praefect-1, Praefect-2, Praefect-3,
                Gitaly-1, Gitaly-2, Gitaly-3
```

Each server gets its own certificate and private key. All six trust the same public CA certificate. HAProxy only forwards encrypted TCP traffic, so it gets no certificate or key.

| File | What it is | Where it goes |
|---|---|---|
| `ca/ca.key` | CA's signing key — very sensitive | Protected offline storage only; never a VM or Git |
| `ca/ca.crt` | Public CA certificate | The six storage VMs and GitLab client |
| `NODE.key` | That one server's private key — sensitive | Only its matching VM |
| `NODE.crt` | That server's signed certificate | Only its matching VM |
| `NODE.csr`, `NODE.ext` | Temporary request and signing details | Keep with your protected local certificate records |

The certificates answer “is this really the server I meant to contact?” The tokens answer “is this caller allowed to use the service?”

## Keep these two certificate authorities separate

- **Your lab CA** signs Praefect and Gitaly certificates. You create it below.
- **AWS RDS CA bundle** verifies RDS's certificate. AWS supplies it; do not create it. Praefect needs it for encrypted database connections. The main guide installs it.

## Part 1 — Make the CA once

Do this only if you do not already have the lab CA. If you already have `ca/ca.key` and `ca/ca.crt`, keep them and skip to Part 2. **Do not make a new CA just to renew server certificates.**

On your trusted laptop:

```bash
umask 077
mkdir -p ~/gitaly-lab-private
chmod 700 ~/gitaly-lab-private
cd ~/gitaly-lab-private
mkdir -m 700 ca
```

Create the CA's encrypted private key. OpenSSL asks you to choose a passphrase; save it securely because you will need it when signing certificates:

```bash
openssl genpkey -algorithm RSA -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:3072 -out ca/ca.key
```

Create the CA's public certificate (valid about three years):

```bash
openssl req -new -x509 -sha256 -days 1095 \
  -key ca/ca.key -out ca/ca.crt \
  -subj '/CN=Gitaly Lab Root CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -addext 'subjectKeyIdentifier=hash'
```

Check that it was created:

```bash
openssl verify -CAfile ca/ca.crt ca/ca.crt
openssl x509 -in ca/ca.crt -noout -subject -dates
```

The first command should print `OK`. `ca/ca.key` is the important secret; never upload it.

## Part 2 — Make six server certificates

A server certificate must list the DNS name clients use to reach that server. This name is called its **SAN**. Praefect certificates need two names: their private node name and the shared public endpoint, because HAProxy can route clients to any Praefect node.

Create a fresh certificate batch. Do not reuse an existing batch directory:

```bash
cd ~/gitaly-lab-private
BATCH=batch-01
mkdir -m 700 "$BATCH"
```

For each of the six rows in the table below, set `NODE` and `SANS` to that row, then run the command block immediately after it. Do not change the block. It creates a new private key and certificate for that node, signed by your existing CA.

| Node | Set `NODE` to | Set `SANS` to |
|---|---|---|
| Gitaly 1 | `gitaly-1` | `DNS:gitaly-1.gitaly-lab.internal` |
| Gitaly 2 | `gitaly-2` | `DNS:gitaly-2.gitaly-lab.internal` |
| Gitaly 3 | `gitaly-3` | `DNS:gitaly-3.gitaly-lab.internal` |
| Praefect 1 | `praefect-1` | `DNS:praefect-1.gitaly-lab.internal,DNS:praefect-lab.tyagi.fun` |
| Praefect 2 | `praefect-2` | `DNS:praefect-2.gitaly-lab.internal,DNS:praefect-lab.tyagi.fun` |
| Praefect 3 | `praefect-3` | `DNS:praefect-3.gitaly-lab.internal,DNS:praefect-lab.tyagi.fun` |

Example for the first row: set these two values, then run the block:

```bash
NODE=gitaly-1
SANS='DNS:gitaly-1.gitaly-lab.internal'
```

Run this block once for that node, then repeat for each remaining row after changing `NODE` and `SANS` as shown above:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$BATCH/$NODE.key"

openssl req -new -key "$BATCH/$NODE.key" \
  -subj "/CN=$NODE.gitaly-lab.internal" \
  -out "$BATCH/$NODE.csr"

printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  'subjectKeyIdentifier=hash' \
  'authorityKeyIdentifier=keyid,issuer' \
  "subjectAltName=$SANS" > "$BATCH/$NODE.ext"

openssl x509 -in ca/ca.crt -noout -checkend 7776000 || {
  echo 'CA expires in less than 90 days. Stop and plan CA replacement.' >&2
  exit 1
}

openssl x509 -req -sha256 -days 90 \
  -in "$BATCH/$NODE.csr" \
  -CA ca/ca.crt -CAkey ca/ca.key \
  -set_serial "0x$(openssl rand -hex 16)" \
  -extfile "$BATCH/$NODE.ext" \
  -out "$BATCH/$NODE.crt"
```

OpenSSL asks for the CA passphrase when signing. That is expected. Each certificate lasts 90 days. Do not share the node's private key with another node.

### Check each certificate

For each node, set `NODE` to the name and run:

```bash
openssl verify -CAfile ca/ca.crt -purpose sslserver \
  -verify_hostname "$NODE.gitaly-lab.internal" "$BATCH/$NODE.crt"
openssl x509 -in "$BATCH/$NODE.crt" -noout -dates -ext subjectAltName
```

The verify command should say `OK`. For Praefect nodes, also check that the shared endpoint is on the certificate. Set `NODE` to the Praefect name first:

```bash
openssl verify -CAfile ca/ca.crt -purpose sslserver \
  -verify_hostname praefect-lab.tyagi.fun "$BATCH/$NODE.crt"
```

If a check fails, stop and fix the certificate before copying it to a VM.

## Part 3 — Put the right files in the right places

Upload only the matching node's certificate and key, plus the public CA certificate. For example, from your protected working directory:

```bash
scp -i /path/to/lab-key.pem \
  batch-01/gitaly-1.crt batch-01/gitaly-1.key ca/ca.crt \
  ubuntu@REPLACE_GITALY1_PUBLIC_IP:/home/ubuntu/
```

Repeat with each node's own filenames and IP. Then use the certificate installation steps in [the main guide](README.md#10-issue-and-install-certificates).

- Storage VMs receive their own `.crt` and `.key`, and the public `ca.crt`.
- Praefect VMs also receive the AWS RDS bundle as described in the main guide.
- GitLab client pods receive the public `ca.crt` through the chart's custom CA configuration.
- HAProxy receives none of these files.
- **Never copy `ca/ca.key` to a VM or Kubernetes.**

## Part 4 — Understand the connection

When GitLab connects to `praefect-lab.tyagi.fun:443`, HAProxy forwards the encrypted connection to one Praefect node. Praefect presents its certificate. GitLab checks that the certificate was signed by the trusted `ca.crt`, contains the requested hostname, and has not expired. TLS then encrypts the connection. Praefect separately checks its application token.

Praefect and Gitaly use the same kind of TLS checks for their internal connections. Gitaly-to-Gitaly connections do too. This is why every server needs the right certificate and the clients need to trust the CA.

After setup, the TLS endpoint can be checked from your allowlisted laptop:

```bash
openssl s_client -connect praefect-lab.tyagi.fun:443 \
  -servername praefect-lab.tyagi.fun -alpn h2 \
  -CAfile ca/ca.crt \
  -verify_hostname praefect-lab.tyagi.fun \
  -verify_return_error </dev/null
```

Look for successful certificate verification. This checks TLS only; it does not prove the database, replication, or Git push works.

## Renew later — not part of first-time setup

Leaf certificates last 90 days; plan to replace them around day 60. For ordinary renewal:

1. Keep the same CA and create a **new** batch, such as `batch-02`.
2. Make new leaf certificates with the steps in Part 2. Do not run the CA creation steps again.
3. Install and activate them one node at a time using [TLS-RENEWAL.md](TLS-RENEWAL.md).
4. Verify the service and cluster health before moving to the next node.

A service restart is needed to load a replacement certificate. Rolling nodes helps keep replicas available, but an active Git operation may still be interrupted. Do not promise zero downtime. CA replacement is a different, more involved procedure; see [the CA replacement section](TLS-RENEWAL.md#6-ca-replacement-is-a-different-operation).

## Common problems

| Message/symptom | First thing to check |
|---|---|
| Unknown authority | The client has the correct public `ca.crt` installed and trusts it. |
| Hostname mismatch | The certificate's SAN includes the exact DNS name used by the client. |
| Expired or not yet valid | Certificate dates and server clock. |
| Certificate/key mismatch | The certificate and key came from the same node and batch. |
| Connection timeout | DNS, routes, firewall/security-group rules, and whether the service is listening. This is not fixed by making a new certificate. |
| TLS works but RPC is denied | Check the Praefect/Gitaly token; certificates do not grant application access. |
