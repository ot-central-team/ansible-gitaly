# Create an IRSA role for your pods in EKS to access AWS resources

Example: give your `nginx` Deployment access to S3 using ServiceAccount
`s3-access-nginx` and IAM role `s3-access-eks`.

## 1. Copy the EKS OIDC provider URL

Open **AWS Console → EKS → Your cluster → Overview → Cluster info**.
Copy **OpenID Connect provider URL**. Do not copy the Kubernetes API endpoint.

## 2. Create the IAM identity provider

Open **IAM → Identity providers → Add provider**:

- **Provider type:** OpenID Connect
- **Provider URL:** paste your EKS OIDC provider URL
- **Audience:** `sts.amazonaws.com`

Choose **Add provider**. If this exact provider already exists, reuse it and
verify its audience. Spell `sts.amazonaws.com` exactly.

## 3. Create the IAM role

Open **IAM → Roles → Create role**:

1. Select **Web identity**.
2. Choose the identity provider from step 2.
3. Select audience **`sts.amazonaws.com`**.
4. Choose **Next**, then select the required permission policy. For your S3
   practice exercise, this can be **AmazonS3FullAccess**. For GitLab production,
   use the bucket-scoped policy in [eks/s3-policy.json](eks/s3-policy.json).
5. Choose **Next**, name the role **`s3-access-eks`**, and create it.
6. Copy the role's **ARN**.

In the new role, open **Trust relationships → Edit trust policy**. Keep the
existing provider and `sts:AssumeRoleWithWebIdentity` action. Under
`Condition.StringEquals`, keep the audience and add the ServiceAccount subject:

```json
"StringEquals": {
  "<OIDC_PROVIDER_WITHOUT_HTTPS>:aud": "sts.amazonaws.com",
  "<OIDC_PROVIDER_WITHOUT_HTTPS>:sub": "system:serviceaccount:nginx:s3-access-nginx"
}
```

This is a fragment of the existing policy, not a replacement for the entire
JSON. Replace `<OIDC_PROVIDER_WITHOUT_HTTPS>` with your issuer, for example
`oidc.eks.ap-south-1.amazonaws.com/id/YOUR_CLUSTER_ID`. Save the policy.
The `sub` condition restricts the role to this namespace and ServiceAccount.

## 4. Create the Kubernetes ServiceAccount

Run from your laptop or bastion with kubectl connected to the correct cluster.
The `nginx` namespace must already exist.

```bash
kubectl create sa s3-access-nginx -n nginx
```

If the ServiceAccount already exists, reuse it. Attach the role ARN as an annotation:

```bash
kubectl annotate serviceaccount s3-access-nginx -n nginx \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/s3-access-eks \
  --overwrite
```

Replace `<ACCOUNT_ID>` with your account ID, or paste the complete role ARN
copied in step 3. Do not attach this application role to the worker VM.

## 5. Set the ServiceAccount in your Deployment

```bash
kubectl edit deployment nginx -n nginx
```

Add `serviceAccountName` under **`spec.template.spec`**, at the same indentation
level as `containers`. Keep the existing container configuration:

```yaml
spec:
  template:
    spec:
      serviceAccountName: s3-access-nginx
      containers:
        # Keep your existing containers here.
```

Save and exit the editor. Changing the pod template automatically starts a
rollout. If the Deployment already used this ServiceAccount and you only added
or changed its role annotation, recreate its pods instead:

```bash
kubectl rollout restart deployment nginx -n nginx
```

Wait for the new pods:

```bash
kubectl rollout status deployment nginx -n nginx
kubectl get pods -n nginx
```

## 6. Verify AWS access

If AWS CLI is installed in the application container, run:

```bash
kubectl exec -n nginx deployment/nginx -- aws sts get-caller-identity
kubectl exec -n nginx deployment/nginx -- aws s3 ls
```

The identity should contain **`assumed-role/s3-access-eks/`**. With the lab's
`AmazonS3FullAccess` policy, the second command lists your buckets. With a
bucket-scoped policy, test the permitted bucket instead:

```bash
kubectl exec -n nginx deployment/nginx -- aws s3 ls s3://YOUR_ALLOWED_BUCKET/
```

A standard nginx image does not include AWS CLI; these verification commands
assume you have installed it as in your practice pod. Recreated pods lose
packages installed manually inside old containers. The application itself needs
an IRSA-compatible AWS SDK, not necessarily AWS CLI.

No Kubernetes RoleBinding is required for this AWS access. The connection is:

```text
Deployment → ServiceAccount → IAM role → permission policy → AWS resource
```

References: [Create the IAM OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)
and [associate an IAM role with a ServiceAccount](https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html).
