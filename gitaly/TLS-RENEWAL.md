# TLS lifecycle — renew before expiry, one node at a time

Use this after [the lab](README.md) is working. This procedure assumes the HAProxy path; with NLB, use target deregistration/draining and re-registration instead of HAProxy commands.

## What can we honestly promise?

A trusted private CA is suitable for this controlled lab. There is no certificate purchase cost, but you own secure issuance, trust distribution, monitoring and renewal. The CA key stays offline; each VM has only its own unencrypted leaf key, protected by filesystem permissions.

**Do not promise zero interrupted operations.** Gitaly must restart to load replacement certificates; merely replacing files and running reconfigure does not guarantee a reload. A rolling process keeps other replicas available, but active Git RPCs can fail and require retries. Schedule a quiet window and avoid concurrent maintenance. Single HAProxy and Single-AZ RDS remain single points of failure independently of TLS. [GitLab certificate reload behavior](https://docs.gitlab.com/administration/gitaly/tls_support/#update-the-certificates)

## 1. Schedule and check expiry

The script issues 90-day leaf certificates. Renew at day60; alert with 30/14/7 days remaining. Check the root separately and begin its rollover at least90 days before it expires. A calendar reminder is a minimum POC measure, not automated monitoring.

On every VM:

```bash
openssl x509 -in /etc/gitlab/ssl/current/server.crt -noout -subject -issuer -dates
openssl x509 -in /etc/gitlab/ssl/current/server.crt -noout -checkend 2592000
openssl x509 -in /etc/gitlab/trusted-certs/gitaly-lab-ca.crt -noout -checkend 7776000
```

`-checkend` exits nonzero if the certificate expires within that many seconds. Connect these checks to your monitoring/alerts; don't just run them on installation day. Also monitor RDS's separate AWS-issued certificate and follow AWS's rotation notices.

## 2. Issue replacement leaves with the SAME CA

For issuance without the script, follow [Manual TLS §10](MANUAL-TLS-README.md#10-expiry-and-manual-renewal), then continue with §3 below. Both methods produce the same per-node files.

On your protected laptop directory from setup:

```bash
cd ~/gitaly-lab-private
bash /REPLACE_PROJECT_PATH/gitaly/make-certs.sh issue batch-02 praefect-lab.tyagi.fun
```

Do NOT run `init-ca` again for routine renewal. Same CA + same DNS names means clients do not need a new trust anchor. New private leaf keys are generated. Copy each new certificate/key only to its own VM using the setup `scp` pattern; do not switch six nodes together.

Before starting, ensure all three Gitaly replicas are current, all Praefect checks pass, clocks are synchronized (`timedatectl status`), and a fresh clone/push succeeds. Defer if any node or replica is unhealthy. Keep the old leaf files for rollback while valid; never roll back to an expired or compromised key.

## 3. Stage and verify on ONE VM

Example `NODE=praefect-1`; substitute the node you are actually renewing. The new files must already be in `/home/ubuntu/`.

```bash
NODE=praefect-1
openssl verify -CAfile /etc/gitlab/trusted-certs/gitaly-lab-ca.crt "/home/ubuntu/$NODE.crt"
openssl x509 -in "/home/ubuntu/$NODE.crt" -noout -checkhost "$NODE.gitaly-lab.internal"
openssl x509 -in "/home/ubuntu/$NODE.crt" -noout -dates
openssl x509 -in "/home/ubuntu/$NODE.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum
openssl pkey -in "/home/ubuntu/$NODE.key" -pubout -outform DER | sha256sum
```

Both SHA256 hashes must match. On Praefect additionally run `openssl x509 -in "/home/ubuntu/$NODE.crt" -noout -checkhost praefect-lab.tyagi.fun`. Stop on any verification failure.

```bash
sudo install -d -o root -g git -m 0750 /etc/gitlab/ssl/batch-02
sudo install -o root -g git -m 0644 "/home/ubuntu/$NODE.crt" /etc/gitlab/ssl/batch-02/server.crt
sudo install -o root -g git -m 0640 "/home/ubuntu/$NODE.key" /etc/gitlab/ssl/batch-02/server.key
readlink -f /etc/gitlab/ssl/current
```

Record that last path for rollback. Use a NEW batch directory every cycle, never overwrite the active directory. The commands below assume `current.next` does not already exist; inspect/remove only a known stale staging link if a previous attempt left it.

## 4. Roll Praefect-1, then 2, then 3

On the dedicated `haproxy-1` host, drain the chosen backend (`p1`, `p2`, or `p3`):

```bash
echo 'set server praefect/p1 state drain' | sudo socat stdio /run/haproxy/admin.sock
echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock
```

Inspect its `scur` (current sessions) column. Wait for existing sessions to finish before restart. Long-lived gRPC connections can remain open: **draining is not a guarantee of a quick, interruption-free restart**. If they do not clear in the agreed window, postpone or coordinate client quiescence/reconnection; do not force-kill and claim zero downtime. Runtime drain state may be lost if HAProxy reloads/restarts, so avoid proxy maintenance during the sequence. [HAProxy drain state](https://www.haproxy.com/documentation/haproxy-runtime-api/reference/set-server/)

On that Praefect VM, atomically switch the certificate/key pair and restart ONLY Praefect:

```bash
sudo ln -s /etc/gitlab/ssl/batch-02 /etc/gitlab/ssl/current.next
sudo mv -Tf /etc/gitlab/ssl/current.next /etc/gitlab/ssl/current
sudo gitlab-ctl restart praefect
sudo -u git env SSL_CERT_DIR=/opt/gitlab/embedded/ssl/certs /opt/gitlab/embedded/bin/praefect -config /var/opt/gitlab/praefect/config.toml check
```

From a Praefect VM, test the renewed node directly using its actual private hostname (change the `1` as needed):

```bash
openssl s_client -connect praefect-1.gitaly-lab.internal:3305 -servername praefect-lab.tyagi.fun -alpn h2 -CAfile /etc/gitlab/trusted-certs/gitaly-lab-ca.crt -verify_hostname praefect-lab.tyagi.fun -verify_return_error </dev/null
```

Confirm verification and the served certificate's new serial/expiry (use `-showcerts` and inspect the leaf if needed). Then on HAProxy:

```bash
echo 'set server praefect/p1 state ready' | sudo socat stdio /run/haproxy/admin.sock
echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock
```

Run an application clone/push test and health checks before repeating on p2, then p3. Do **not** reboot the separate `haproxy-1` VM or restart HAProxy for this operation; that would affect the only entry point. HAProxy has no certificate to rotate and none of these leaf keys should be installed there.

## 5. Roll Gitaly-1, then 2, then 3

For each Gitaly node: stage/verify its files (§3), ensure the other two replicas are healthy/current, switch `current` with the same two symlink commands, then run `sudo gitlab-ctl restart gitaly` on that node only.

From a Praefect VM, verify its direct TLS endpoint (`gitaly-N.gitaly-lab.internal:9999`) using that same hostname for `-servername` and `-verify_hostname`, ALPN `h2`, and the lab CA. Repeat the Praefect health and `dataloss -virtual-storage default -partially-unavailable` checks in the README. Wait for all replicas to recover and retest clone/push before renewing the next node. HAProxy backend drain does **not** drain a Gitaly node: it only controls Praefect connections.

For a failed rotation, stop the sequence. Restore `current` to the recorded old batch using a new temporary symlink and `mv -Tf`, restart the affected service, and recheck health. Keep the other nodes untouched while investigating.

## 6. CA replacement is a different operation

When the root approaches expiry, or you deliberately replace it:

1. Create a new protected CA in a **different local directory**; keep the old one intact for the overlap period.
2. FIRST distribute the new CA certificate alongside the old one to both OS/package trust stores on all six storage VMs (not HAProxy), and to all GitLab client pods via an additional custom-CA Secret. Give the new file/key a distinct name.
3. Run package reconfigure and rolling service restarts as required to load the combined trust; roll GitLab client workloads as necessary. Verify all clients still work with the old leaves before switching any leaf.
4. Issue leaves signed by the new CA; roll them node by node using the procedure above. Keep both trust anchors throughout.
5. Verify every endpoint serves the new chain and all clients have the new trust. Only then remove old trust anchors in a separate controlled rollout and retire the old CA securely.

If a key is compromised, do not follow a leisurely expiry timeline or assume this setup automatically enforces certificate revocation. Contain access, coordinate replacement and removal of compromised trust/credentials, and accept a maintenance window if needed.

## Another no-certificate-fee option

Let's Encrypt with **DNS-01** can issue for names under a domain you control even when services are private. You would rename the `.internal` backends to real names such as `gitaly-1.lab.tyagi.fun`; private `.internal` names cannot get public certificates. DNS-01 proves domain control using TXT records, so port80 does not need opening on the VMs. Public certificates expose names in certificate-transparency logs. [Let's Encrypt DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)

This still needs a secured DNS automation identity, automated renewal, distribution, service reload/restart handling, and expiry alerts. It is not automatically “zero downtime.” AWS Private CA is a paid service, not the free replacement for this lab. For now the provided offline private-CA method is the simpler path.
