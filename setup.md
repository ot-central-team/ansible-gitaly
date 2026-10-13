# GitLab on EKS — setup handbook

This deploys the application half of your GitLab installation. It reuses the
existing Gitaly → Praefect → NLB setup. Run the steps in order from a trusted
admin machine with access to EKS and AWS; run the database step from the bastion.
These files do not create cloud resources until you execute the commands.

## 1. What will run where

```text
Browser / Git HTTPS / CI jobs
  → gitlab.opstree.dev:443 → AWS ALB → ClusterIP → Workhorse + Rails pods
                                                  │
Sidekiq pods ──────────────────────────────────────┤
Toolbox / migration jobs ──────────────────────────┤
                                                  ├→ Rails RDS PostgreSQL
                                                  ├→ ElastiCache Redis
                                                  ├→ S3 via IAM roles
                                                  └→ nlb.tyagi.fun:443
                                                      → Praefect:3305
                                                        → Gitaly nodes:9999
Gitaly hooks → https://gitlab.opstree.dev/api/v4/internal/...
```

| Workload | Deployment / purpose |
|---|---|
| Webservice | One Deployment, initially 4 pods; each has Rails/Puma and Workhorse containers |
| Sidekiq | Separate Deployment, initially 8 pods; background jobs |
| Toolbox | One Deployment, 1 pod; administration and backups |
| GitLab exporter | Small supporting Deployment for metrics |
| Migrations and shared secrets | Short-lived Jobs managed by the GitLab chart, not permanent Deployments |
| Runner | Separate Helm release and manager Deployment; starts temporary CI job pods on CI nodes |

Existing EKS, AWS Load Balancer Controller, EBS CSI driver, Metrics Server and
node autoscaling are infrastructure prerequisites. There are no NetworkPolicy
manifests here. No Kubernetes PostgreSQL, Redis, Gitaly or Praefect is deployed.

Scope: UI, API, Git over HTTPS, LFS, artifacts, uploads, packages, Terraform
state, secure files, background jobs and CI. Git SSH, Container Registry, Pages,
KAS/agent integration, dependency proxy and advanced search are disabled.
Use an external image registry such as ECR for now. ALB cannot carry Git SSH.

## 2. Capacity and production gate

This assumes **2,000 registered users and around 500 active users**, not 500
simultaneous CI jobs. User count alone cannot size a system. Start with these
requests, then test your repositories, API traffic, pushes and pipelines:

| Component | Initial → maximum | Requests per pod |
|---|---|---|
| Webservice | 4 → 8 | Rails: 4 CPU, 5 GiB; 4 Puma workers, plus Workhorse/init overhead |
| Sidekiq | 8 → 12 | 900m CPU, 2 GiB; concurrency 20 |
| Toolbox | 1 | 1 CPU, 2 GiB; 200 GiB scratch PVC |
| Runner manager | 1 | 250m CPU, 256 MiB; 10 simultaneous CI jobs initially |

These application settings follow the shape of GitLab's
[3K hybrid reference baseline](https://docs.gitlab.com/administration/reference_architectures/3k_users/),
which is the smallest reference topology with HA. They are a starting point,
not a measured guarantee for your workload.

Use private, on-demand **application nodes in three AZs**, labelled
`workload=gitlab-app`. A starting pool is three `m6i.4xlarge` nodes, autoscaling to
six. Include system pods, limits, upgrade surge and one-node/AZ loss in capacity
calculations; increase the minimum if the remaining nodes cannot hold your
measured peak. HPA requires Metrics Server; node autoscaling must also be configured.
Use separate CI nodes labelled `workload=gitlab-ci` and tainted
`workload=gitlab-ci:NoSchedule`. Size CI nodes for build CPU/memory and job count.
Untrusted CI should use a separate cluster before wider multi-tenant use.

**NLB does not make a single Praefect node highly available.** Two small Gitaly VMs are not a validated production backend for
this load. Before production, review the supported three-Gitaly/three-Praefect
topology across AZs, a redundant supported TCP load-balancing endpoint, and HA
for the Praefect database. Repository replicas do not replace backups.
Gitaly Cluster is available in Free, Premium and Ultimate; GitLab's technical
support for Praefect is limited to Premium and Ultimate. See
[Gitaly Cluster requirements](https://docs.gitlab.com/administration/gitaly/praefect/).

## 3. Versions and local working files

The provided values are validated against **GitLab chart 10.4.1 = GitLab
19.4.1**, matching `19.4.1-ee.0` in this repository's Ansible inventory. Runner
chart **0.93.0 = Runner 19.4.0** is separate. Do not override individual GitLab
image tags or install an arbitrary newer application version over older Gitaly.

The official chart index already lists **10.4.2 / 19.4.2** at preparation time.
The 10.4.1 pin is for compatibility with your existing installation, **not a
claim that it is the newest security patch**. Before public production rollout,
review [GitLab releases](https://about.gitlab.com/releases/), stage the current
supported patch upgrade across Gitaly/Praefect and EKS, and revalidate the chart.
Never silently downgrade an installed component.

Use AWS CLI v2, kubectl compatible with your EKS version, Helm 3, Python 3,
OpenSSL, Git, and PostgreSQL 17 client for database administration. Confirm the
cluster version meets the [chart prerequisites](https://docs.gitlab.com/charts/installation/tools/).
Commands below assume Bash, repository root, AWS region Mumbai, Helm release
name `gitlab` and namespace `gitlab`. Changing these names requires changing
the Ingress backend, selectors and IAM trust subjects too.

```bash
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION="$AWS_REGION"
export EKS_CLUSTER=REPLACE_EKS_CLUSTER_NAME
export BUCKET_PREFIX=REPLACE_GLOBALLY_UNIQUE_PREFIX
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION"
kubectl config current-context
kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl -n kube-system get deployment aws-load-balancer-controller metrics-server
kubectl -n kube-system get deployment ebs-csi-controller

umask 077
mkdir -p eks/local/secrets eks/local/rds-ca
cp eks/gitlab-values.yaml eks/local/gitlab-values.yaml
cp eks/prerequisites.yaml eks/local/prerequisites.yaml
cp eks/alb-ingress.yaml eks/local/alb-ingress.yaml
cp eks/runner-values.yaml eks/local/runner-values.yaml
```

`eks/local/` is Git-ignored. Keep passwords and generated manifests there;
rendered Helm output can contain Secrets. Do not rerun the copy commands over
your edited configuration. Leave the checked-in files as reusable templates.

## 4. AWS resources and networking

Create these in the same region/VPC, using the AWS console or your approved
infrastructure workflow. EKS workloads need private routing to the backends.

| Resource | Settings for this starting deployment |
|---|---|
| Rails RDS | PostgreSQL **17**, current minor; a new instance, not the Praefect RDS; Multi-AZ; initial `db.m7g.xlarge`; encrypted gp3, start 200 GiB with storage autoscaling; private subnet group; public access No; deletion protection; 14+ day automated backups |
| Redis | ElastiCache **Redis OSS 7.1** replication group, cluster mode **disabled**; primary + 2 replicas in separate AZs; Multi-AZ/automatic failover; initial `cache.r7g.large`; encryption at rest and in transit; AUTH token; daily snapshots |
| Redis parameters | Custom `redis7` parameter group, `maxmemory-policy=noeviction`; use the **primary endpoint**, not a reader or individual-node endpoint |
| S3 | Seven application buckets plus backups and restore-temp, created below |
| TLS | ACM certificate in `ap-south-1` covering `gitlab.opstree.dev`, DNS validation completed |
| Email | SES verified `opstree.dev` domain, DKIM/SPF/DMARC, production sending access and SMTP credentials in this region |
| ALB | Created by the Ingress after GitLab installation; public subnets in multiple AZs, private pod IP targets |

PostgreSQL 17 and the selected Redis family meet the documented
[GitLab 19 requirements](https://docs.gitlab.com/install/requirements/).
Do not select Redis Cluster mode or ElastiCache Serverless. One Redis group is
used initially for simplicity; monitor memory and eviction/OOM failures closely
and separate cache from persistent queues as load requires. Do not use a small
burstable RDS/Redis instance for the stated production load.

On RDS use a custom `postgres17` parameter group with `rds.force_ssl=1`.
Review `max_connections` against all web workers, Sidekiq threads, both Rails
logical database pools, migrations and administrative connections **at maximum
replicas**. Keep headroom and alert before exhausting connections. Do not raise
HPA limits without reviewing RDS capacity; add supported connection pooling if
the connection budget demands it. This setup uses direct RDS connections.

Allow only required traffic in security groups and host firewalls:

| Source | Destination | TCP port |
|---|---|---|
| Approved users/CI clients and Gitaly callback egress | ALB | 443 (80 redirects) |
| ALB security group | Webservice pod/node security group | 8181 |
| Application pods + bastion | Rails RDS | 5432 |
| Application pods | Redis primary/replicas | 6379 |
| Application pods | NLB endpoint | 443 |
| NLB | Praefect | 3305 |
| Praefect and Gitaly peers | Gitaly | 9999 |
| Praefect | Existing Praefect RDS | 5432 |
| Application/CI nodes | DNS, image registries, S3, regional STS, SMTP | DNS 53; HTTPS 443; SMTP 587 as needed |

Use the **actual pod source security group/IP path**, accounting for VPC CNI,
NAT, custom networking and any security groups for pods. Private DNS/routing to
`nlb.tyagi.fun` must resolve through a CNAME to the internal NLB DNS name.
EKS must have private network access to that VPC; public DNS does not provide
an internet route. Do not expose 3305 or 9999 publicly. Existing ALB controller
permissions must allow target registration and backend SG updates.

This baseline terminates TLS at ALB and uses HTTP to Workhorse inside the
private VPC. RDS, Redis and NLB connections use TLS. If your policy requires
TLS on the ALB-to-pod leg, configure Workhorse backend TLS before launch; do not
describe this baseline as end-to-end encrypted.

## 5. Create the Rails database from the bastion

The Ansible `db` role provisions **Praefect's** database. It is not used here.
Create a fresh RDS instance with master username `postgres` and leave its initial
application database name blank. Download the AWS public CA bundle:

```bash
curl --fail --location https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  --output eks/local/rds-global-bundle.pem
export RAILS_DB_HOST=REPLACE_RAILS_RDS_ENDPOINT
psql "host=$RAILS_DB_HOST port=5432 dbname=postgres user=postgres sslmode=verify-full sslrootcert=$PWD/eks/local/rds-global-bundle.pem" \
  -W -f eks/prepare-rails-db.sql
```

Enter the master password at the connection prompt. The script then asks twice
for the **new `gitlab` application user's password**. It creates the role,
temporarily grants it to the master so the master can create an owned database,
creates `gitlabhq_production`, revokes that temporary membership, and installs
required extensions. No master password goes to EKS. This is a **fresh database
script**, not an idempotent reset; if it fails partway, inspect the state and
resume the remaining statements instead of dropping data or repeating creation.

Verify as the application user, using the password just chosen:

```bash
psql "host=$RAILS_DB_HOST port=5432 dbname=gitlabhq_production user=gitlab sslmode=verify-full sslrootcert=$PWD/eks/local/rds-global-bundle.pem" -W
```

Inside psql, execute the lines separately:

```sql
SELECT current_user, current_database();
SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();
BEGIN;
CREATE TABLE public.bootstrap_check (id integer);
INSERT INTO public.bootstrap_check VALUES (1);
SELECT * FROM public.bootstrap_check;
ROLLBACK;
\q
```

The Helm migrations Job creates Rails application tables later. This is
independent of your already-completed **Praefect** migrations. The chart uses
the same Rails database for its default `main` and `ci` connections in this
setup. [External database setup](https://docs.gitlab.com/charts/advanced/external-db/).

## 6. Create S3 buckets

Run once with a globally unique prefix reserved for this deployment. Commands
create AWS resources and incur storage/request charges. If a bucket already
exists, verify its account/ownership and settings before resuming; do not ignore
a creation error.

```bash
(
set -euo pipefail
for suffix in artifacts lfs uploads packages mr-diffs terraform-state ci-secure-files backups restore-tmp; do
  bucket="$BUCKET_PREFIX-$suffix"
  aws s3api create-bucket --bucket "$bucket" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
  aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "$bucket" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-policy --bucket "$bucket" --policy \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$bucket\",\"arn:aws:s3:::$bucket/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
done
)
```

These use SSE-S3; using customer-managed KMS requires additional IAM/KMS grants.
Do not enable blanket object expiration on application buckets: GitLab manages
their lifecycle. Establish backup retention/noncurrent-version cleanup after
agreeing RPO/RTO; versioning alone can grow without bound. Keep backups in a
separate account or replicated location according to your recovery policy.

## 7. Give pods S3 permissions through IRSA

New to OIDC, IAM roles and ServiceAccounts? First work through the separate
[OIDC and IRSA learning lab](OIDC-IRSA-LAB.md). It demonstrates the flow with
one temporary read-only S3 pod before you configure GitLab's roles.

Associate the EKS OIDC provider if not already present (requires `eksctl` and
IAM permissions). Existing EKS Pod Identity is a different mechanism; these
files specifically use **IRSA**.

```bash
eksctl utils associate-iam-oidc-provider --cluster "$EKS_CLUSTER" --region "$AWS_REGION" --approve
export OIDC_PROVIDER=$(aws eks describe-cluster --name "$EKS_CLUSTER" \
  --query cluster.identity.oidc.issuer --output text | sed 's|https://||')
```

Generate two scoped policies and trust files. Rails gets the seven application
buckets; Toolbox additionally gets backups/restore-temp. CI job pods get neither.

```bash
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path('eks/local')
prefix = os.environ['BUCKET_PREFIX']
policy = json.loads(Path('eks/s3-policy.json').read_text().replace('REPLACE_BUCKET_PREFIX', prefix))
(p / 'rails-s3-policy.json').write_text(json.dumps(policy, indent=2))
for suffix in ('backups', 'restore-tmp'):
    policy['Statement'][0]['Resource'].append(f'arn:aws:s3:::{prefix}-{suffix}')
    policy['Statement'][1]['Resource'].append(f'arn:aws:s3:::{prefix}-{suffix}/*')
(p / 'toolbox-s3-policy.json').write_text(json.dumps(policy, indent=2))
for sa in ('gitlab-rails', 'gitlab-toolbox'):
    trust = Path('eks/irsa-trust.json').read_text()
    for name, value in {'REPLACE_ACCOUNT_ID': os.environ['AWS_ACCOUNT_ID'],
                        'REPLACE_OIDC_PROVIDER': os.environ['OIDC_PROVIDER'],
                        'REPLACE_SERVICE_ACCOUNT': sa}.items():
        trust = trust.replace(name, value)
    (p / f'{sa}-trust.json').write_text(trust)
PY

aws iam create-role --role-name gitlab-rails-s3 \
  --assume-role-policy-document file://eks/local/gitlab-rails-trust.json
aws iam put-role-policy --role-name gitlab-rails-s3 --policy-name gitlab-s3 \
  --policy-document file://eks/local/rails-s3-policy.json
aws iam create-role --role-name gitlab-toolbox-s3 \
  --assume-role-policy-document file://eks/local/gitlab-toolbox-trust.json
aws iam put-role-policy --role-name gitlab-toolbox-s3 --policy-name gitlab-s3 \
  --policy-document file://eks/local/toolbox-s3-policy.json
```

Role names are account-wide; use deployment-specific names if already used and
update the service-account annotations. No `AmazonS3FullAccess` or static AWS
access keys are needed. `automountServiceAccountToken: false` disables the
ordinary Kubernetes API token; the IRSA webhook still injects its separate STS
projected token. [GitLab IAM configuration](https://docs.gitlab.com/charts/advanced/external-object-storage/aws-iam-roles/).

## 8. Fill values and create Kubernetes Secrets

Edit these **local** copies:

| File | Replace/check |
|---|---|
| `eks/local/gitlab-values.yaml` | RDS endpoint, Redis primary endpoint, every bucket prefix; SES sender/domain; capacity |
| `eks/local/prerequisites.yaml` | AWS account ID in the two IAM role ARNs |
| `eks/local/alb-ingress.yaml` | ACM ARN, three public subnet IDs; domain if different |
| `eks/local/runner-values.yaml` | CI concurrency and job limits |

Keep the `gitlab` release name and the service name
`gitlab-webservice-default:8181` consistent. ALB must route through **Workhorse**,
not directly to Rails port 8080. Check for unfilled placeholders:

```bash
grep -n REPLACE_ eks/local/*.yaml
kubectl apply -f eks/local/prerequisites.yaml
```

Resolve every reported placeholder before applying. The second command creates
the two namespaces, service accounts and encrypted gp3 StorageClass, not GitLab.

Create password files without putting values in command history or arguments:

```bash
save_secret() {
  local secret_value
  read -r -s -p "$2: " secret_value
  printf '\n'
  if [ -z "$secret_value" ]; then echo 'Empty value refused'; return 1; fi
  printf '%s' "$secret_value" > "eks/local/secrets/$1"
  unset secret_value
}
save_secret db-password 'Rails gitlab DB user password from step 5'
save_secret redis-password 'ElastiCache AUTH token'
save_secret praefect-token 'EXISTING praefect_external_token from Ansible Vault'
save_secret shell-secret 'Shared gitaly_gitlab_secret_token (see below)'
save_secret smtp-username 'SES SMTP username'
save_secret smtp-password 'SES SMTP password'
```

**Three different GitLab tokens:**

| Token | Where it belongs |
|---|---|
| `praefect_internal_token` | Existing Gitaly + Praefect VMs only; do not send it to EKS |
| `praefect_external_token` | Existing Praefect auth and EKS `praefect-external-token` Secret, key `token` |
| `gitaly_gitlab_secret_token` | Every Gitaly callback configuration and EKS `gitlab-shell-shared`, key `secret` |

Read the existing vaulted values privately. For the Shell secret, reuse the
existing value if configured. If still empty, generate it once with
`openssl rand -hex 32`, save it in your password manager/Ansible Vault and enter
the same value above. Do not regenerate it during each Helm upgrade. The
disabled Git SSH Deployment does not remove the need for this callback secret.
[External Gitaly/Praefect authentication](https://docs.gitlab.com/charts/advanced/external-gitaly/).

Create the Secrets (new installation; use your controlled secret-update workflow
for later rotations):

```bash
kubectl -n gitlab create secret generic gitlab-db-password --from-file=password=eks/local/secrets/db-password
kubectl -n gitlab create secret generic gitlab-redis-password --from-file=password=eks/local/secrets/redis-password
kubectl -n gitlab create secret generic praefect-external-token --from-file=token=eks/local/secrets/praefect-token
kubectl -n gitlab create secret generic gitlab-shell-shared --from-file=secret=eks/local/secrets/shell-secret
kubectl -n gitlab create secret generic gitlab-smtp \
  --from-file=username=eks/local/secrets/smtp-username --from-file=password=eks/local/secrets/smtp-password
kubectl -n gitlab create secret generic gitlab-rails-storage --from-file=connection=eks/object-storage.yaml
```

Download the RDS bundle on this admin machine too if step 5 ran elsewhere. Split
it into individual `.crt` entries for the certificates init container:

```bash
curl --fail --location https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  --output eks/local/rds-global-bundle.pem
python3 - <<'PY'
import re
from pathlib import Path
certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                  Path('eks/local/rds-global-bundle.pem').read_text(), re.S)
assert certs, 'No RDS certificates found'
for i, cert in enumerate(certs):
    Path(f'eks/local/rds-ca/aws-rds-{i:03}.crt').write_text(cert + '\n')
PY
kubectl -n gitlab create secret generic aws-rds-ca --from-file=eks/local/rds-ca
```

The chart adds these CAs to its normal public trust bundle. Follow
[NLB-SETUP.md](NLB-SETUP.md) first: NLB passes TCP through to Praefect, which
presents your publicly trusted certificate for `nlb.tyagi.fun`. EKS therefore
does not need the private internal CA for this endpoint. Praefect still trusts
the private CA when connecting to Gitaly. No TLS private keys belong in EKS.
Public ALB TLS uses ACM, so no Kubernetes ingress TLS Secret is needed.

Store durable copies of these secrets encrypted outside the cluster. Enable
appropriate EKS secret encryption and restrict Secret read/RBAC access. Do not
commit plaintext files or base64-encoded Secret manifests.

## 9. Validate and install GitLab

First verify the backend version on **every Gitaly and Praefect VM**:

```bash
dpkg-query -W -f='${Version}\n' gitlab-ee
sudo gitlab-ctl praefect check # Run this second command on Praefect only.
```

Expect version `19.4.1-ee.0` for the supplied chart pin and all Praefect checks
passing. Then, from the admin machine:

```bash
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm show chart gitlab/gitlab --version 10.4.1
helm pull gitlab/gitlab --version 10.4.1 --destination eks/local
helm template gitlab eks/local/gitlab-10.4.1.tgz -n gitlab \
  -f eks/local/gitlab-values.yaml > eks/local/rendered.yaml
kubectl apply --dry-run=server -f eks/local/rendered.yaml >/dev/null

helm upgrade --install gitlab eks/local/gitlab-10.4.1.tgz \
  --namespace gitlab -f eks/local/gitlab-values.yaml \
  --timeout 30m --wait --wait-for-jobs
```

The dry run checks Kubernetes API acceptance, not connectivity or credentials.
Do not `kubectl apply` the Helm-rendered resources for installation: Helm manages
the hook ordering. We intentionally avoid automatic rollback flags: database
migrations are not undone by rolling back Kubernetes manifests.

The chart's shared-secrets job generates Rails encryption secrets once. Preserve
them for upgrades and disaster recovery. The migrations job initializes the
**Rails** database; do not run a separate manual Rails migration on every pod.

If installation times out, inspect instead of uninstalling/deleting data:

```bash
kubectl -n gitlab get pods,jobs,pvc,hpa,pdb
kubectl -n gitlab get events --sort-by=.lastTimestamp | tail -30
kubectl -n gitlab get jobs -l app=migrations
kubectl -n gitlab logs job/REPLACE_MIGRATIONS_JOB_NAME --all-containers=true
```

Pending pods usually indicate missing node labels/capacity/PVC provisioning.
Migration failures usually need RDS networking, password, version or extension
corrections. Pods can initially wait for migrations; wait for the Job result.

## 10. Publish the ALB endpoint and enable Gitaly callbacks

```bash
kubectl apply -f eks/local/alb-ingress.yaml
kubectl -n gitlab get ingress gitlab
kubectl -n gitlab describe ingress gitlab
kubectl -n gitlab get endpointslices -l kubernetes.io/service-name=gitlab-webservice-default
```

In Route 53 create an alias record `gitlab.opstree.dev` to the ALB (or CNAME at
your DNS provider). Initially use direct DNS, without an additional proxy/CDN,
to validate large Git pushes and timeouts. Check ALB target health; success is
HTTP 200 from `/-/readiness`, not a login redirect. No NLB is created.
ALB annotations are documented by the
[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/).

```bash
curl --fail --show-error https://gitlab.opstree.dev/-/readiness
curl --head https://gitlab.opstree.dev/users/sign_in
```

Now configure the existing Gitaly nodes to reach Rails hooks. In
`inventory/lab/group_vars/gitaly.yml` set:

```yaml
gitaly_configure_gitlab_callbacks: true
gitaly_internal_api_url: https://gitlab.opstree.dev
```

In the existing encrypted `inventory/lab/group_vars/all/vault.yml`, set
`gitaly_gitlab_secret_token` to the **same** secret used in step 8. Then:

```bash
ansible-playbook playbooks/configure_cluster.yml --tags gitaly --ask-vault-pass
```

Gitaly must resolve and reach this domain and trust its public certificate.
Do not append the domain to the private CA or regenerate certificates. This
reconfiguration can restart Gitaly; do it before admitting users. The existing
NLB endpoint remains the repository RPC endpoint; the ALB is the web/API
endpoint. They are different services.

## 11. Verify application and repository operations

From the admin machine, test public TLS to the repository proxy:

```bash
openssl s_client -connect nlb.tyagi.fun:443 \
  -servername nlb.tyagi.fun -verify_hostname nlb.tyagi.fun \
  -verify_return_error -alpn h2 -brief </dev/null
```

Test from the application network as well. Find the Toolbox pod:

```bash
export TOOLBOX_POD=$(kubectl -n gitlab get pod -l app=toolbox,release=gitlab \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n gitlab exec "$TOOLBOX_POD" -- gitlab-rake gitlab:gitaly:check
kubectl -n gitlab exec "$TOOLBOX_POD" -- gitlab-rake gitlab:check SANITIZE=true
kubectl -n gitlab exec "$TOOLBOX_POD" -- aws sts get-caller-identity
kubectl -n gitlab exec "$TOOLBOX_POD" -- aws s3 ls "s3://$BUCKET_PREFIX-artifacts/"
```

The STS ARN must be the Toolbox role. Also verify Webservice/Sidekiq pods have
IRSA projected-token mounts and the expected role, then test uploads/artifacts
through GitLab; Toolbox S3 success alone does not prove Rails permissions.

Retrieve the initial root password privately:

```bash
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 --decode
printf '\n'
```

Sign in as `root`, change the password, enable MFA and configure signup policy.
Set **Admin → Settings → General → Visibility and access controls → Enabled Git
access protocols → Only HTTP(S)** because this setup does not expose SSH.

Create a private test project. Use your Git credential manager/PAT prompt, not a
token embedded in a URL, then clone, commit, push, create a branch and merge
request. Test LFS, an attachment upload/download, and an artifact-producing CI
job. Confirm Sidekiq queues drain and both Gitaly storage replicas remain healthy.
Health probes alone do not verify authentication, hooks, replication or writes.

## 12. Install Runner after GitLab works

In GitLab create an instance/group/project Runner with tag `eks`, choose Linux,
and get its **runner authentication token** (`glrt-...`). Restrict its scope and
protected-branch access as appropriate. Do not use the deprecated registration
token workflow.

```bash
save_secret runner-token 'Runner authentication token (glrt-...)'
kubectl -n gitlab-runner create secret generic gitlab-runner-auth \
  --from-file=runner-token=eks/local/secrets/runner-token \
  --from-literal=runner-registration-token=''
helm upgrade --install gitlab-runner gitlab/gitlab-runner \
  --version 0.93.0 --namespace gitlab-runner \
  -f eks/local/runner-values.yaml --timeout 10m --wait
kubectl -n gitlab-runner get pods
```

Runner's Kubernetes permissions are namespaced. Job pods use the separate
`gitlab-job` account, no Rails IAM role, and run on the tainted CI pool. The node
instance role must not grant application S3/DB credentials; restrict pod access
to EC2 instance metadata. Containers are not privileged; Docker-in-Docker will
not work with this baseline. Distributed build cache is intentionally omitted;
pipeline artifacts still persist through GitLab's S3 storage. Add a dedicated
cache bucket/role later if required. See
[Runner Helm installation](https://docs.gitlab.com/runner/install/kubernetes/).

Test `.gitlab-ci.yml`:

```yaml
smoke:
  image: alpine:3.22
  tags: [eks]
  script:
    - echo 'EKS runner works' > result.txt
  artifacts:
    paths: [result.txt]
```

Confirm the job succeeds, the job pod lands on a CI node, and the artifact can
be downloaded. CI capacity is tuned independently from web users.

## 13. Backups, monitoring and release operations

Run a manual backup first; IRSA needs the AWS CLI backend:

```bash
kubectl -n gitlab exec "$TOOLBOX_POD" -- backup-utility --s3tool awscli
aws s3 ls "s3://$BUCKET_PREFIX-backups/"
```

Size the Toolbox and backup-job scratch PVCs for the actual backup footprint;
200 GiB is a starting value, not a cap on repository size. Toolbox's EBS volume
is AZ-bound; its recovery can require volume restore in another AZ.

Restore a backup into an isolated deployment at the **same GitLab version and
edition**, using the saved Rails encryption secrets. Check repositories,
database, artifacts and LFS. Only after this succeeds set
`gitlab.toolbox.backups.cron.enabled: true` in local values and run the same Helm
upgrade command. The schedule is 20:00 UTC / 01:30 IST with overlapping jobs
forbidden. Verify at least one scheduled backup succeeds.

Back up the following independently, encrypted with access controls:

- Rails Kubernetes Secrets (especially `gitlab-rails-secret`), Helm values,
  inventories and Vault files/password recovery material.
- RDS automated snapshots/PITR for **both** Rails and Praefect databases.
- GitLab application/repository backups and S3 objects; versioning is additional
  protection, not a tested restore plan.
- Bastion private CA key/passphrase and certificate material, and public Praefect TLS
  credentials. Never copy CA private keys into the repository or job pods.

Agree an RPO/RTO and practice a full restore, including Praefect metadata. Do
not assume the Toolbox backup archives Kubernetes Secrets, Praefect database,
or all external object storage. Consult the
[GitLab backup/restore scope](https://docs.gitlab.com/charts/backup-restore/).

Connect the existing monitoring platform to GitLab metrics and AWS CloudWatch.
Alert on ALB errors/latency/unhealthy targets, pod restarts/OOM/Pending state,
HPA at max, Sidekiq queue age, RDS connections/storage/failover, Redis
memory/rejected writes, Praefect replication health, Gitaly disk/latency, failed
backups and certificate expiry. The bundled Prometheus is disabled to avoid
creating an unconfigured monitoring stack; **production needs external monitoring**.
Test SES delivery and password-reset email before onboarding users.

The [TLS renewal workflow](roles/tls/RENEWAL.md) handles private-CA leaf
certificates. Establish and test a
renewal workflow and expiry alerts for the private CA/leaves and public Praefect
certificate before production. Existing certificates surviving re-runs is not
automatic renewal. ACM renews its DNS-validated ALB certificate only while its
validation records and renewal requirements remain satisfied.

For upgrades: read required upgrade stops and release notes, finish background
migrations, back up and restore-test, upgrade the storage components in the
supported order, then upgrade the pinned chart in a maintenance/change window.
Retain all tokens and Rails secrets. Do not rely on `helm rollback` to reverse a
database migration. Repeat the repository/CI tests and load/failure tests before
declaring the change complete.

## Files to maintain

| File | Purpose |
|---|---|
| `eks/gitlab-values.yaml` | Reusable GitLab chart settings; external backends and resource baseline |
| `eks/prerequisites.yaml` | Namespaces, IRSA service accounts, gp3 StorageClass |
| `eks/alb-ingress.yaml` | ALB → Workhorse route and ACM TLS |
| `eks/object-storage.yaml` | Rails S3 connection via IRSA |
| `eks/prepare-rails-db.sql` | Fresh Rails database/user/extensions bootstrap |
| `eks/irsa-trust.json`, `eks/s3-policy.json` | Scoped IAM templates |
| `eks/runner-values.yaml` | Separate Runner manager and CI job settings |
| `eks/local/` | Your ignored deployment copies and sensitive runtime files |

Local validation covers Helm chart rendering and configuration structure. The
AWS endpoints, IAM permissions, secrets, EKS scheduling, ALB routing, load and
restore tests must be verified in your environment before production traffic.
