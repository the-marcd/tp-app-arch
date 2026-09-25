# cluster_base

In-cluster components for the `tp-app` cluster: cert-manager and the AWS Load
Balancer Controller, wired for IRSA on a **self-managed** cluster.

Each directory is a kustomize overlay over a pinned upstream release manifest,
patched rather than vendored. Build one to see what it produces:

```sh
kubectl kustomize cluster_base/cert-manager
```

## IRSA without the pod identity webhook

On EKS, the `amazon-eks-pod-identity-webhook` mutates pods that use an annotated
ServiceAccount, injecting a projected token and the AWS environment variables.
There is no webhook here, so each patch sets the same three things by hand:

| | |
| --- | --- |
| Projected token | `serviceAccountToken` volume, `audience: sts.amazonaws.com`, mounted at `/var/run/secrets/eks.amazonaws.com/serviceaccount` |
| `AWS_ROLE_ARN` | the IRSA role from `infra/` |
| `AWS_WEB_IDENTITY_TOKEN_FILE` | path to that projected token |

Plus `AWS_REGION` / `AWS_DEFAULT_REGION`, which the SDK needs because nothing
else tells these pods what region they are in, and
`AWS_STS_REGIONAL_ENDPOINTS=regional`.

The AWS SDK's default credential chain finds those and calls
`AssumeRoleWithWebIdentity` on its own. The `eks.amazonaws.com/role-arn`
ServiceAccount annotation is also set, but it is **inert** without the webhook —
it is there so the association is discoverable from the cluster.

## Values, and where they came from

Read out of `infra/`'s Terraform state:

| Value | |
| --- | --- |
| Account | `757743287485` |
| Region | `us-east-1` |
| Cluster name | `tp-app` |
| VPC | `vpc-08f394e01158bf14e` |
| Hosted zone | `Z0682799BUTOTN2MXMM1` (`tp.darcsaint.net`) |
| cert-manager role | `arn:aws:iam::757743287485:role/tp-app-cert-manager` |
| LBC role | `arn:aws:iam::757743287485:role/tp-app-aws-load-balancer-controller` |

**The two role ARNs do not exist yet.** `enable_oidc_provider` still defaults to
`false` in `infra/`, so the OIDC provider and all three IRSA roles are absent
from state. The ARNs above are derived from the naming scheme
(`${var.name}-<component>`) and will be correct once phase 2 is applied — but
until then these pods will fail to assume anything.

## Install order

cert-manager first, and not only because the ClusterIssuers need it: the AWS
Load Balancer Controller's own manifest contains cert-manager `Certificate` and
`Issuer` resources for its admission webhook, so its CRDs must be established
first.

```sh
# 0. prerequisites, from infra/
terraform apply -var 'enable_oidc_provider=true' ...   # creates the IRSA roles
#    and the control plane must already have published its OIDC discovery
#    documents to the bucket, or the provider cannot be created at all

# 1. cert-manager
kubectl apply -k cluster_base/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager

# 2. issuers (needs the CRDs from step 1 to be established)
#    EDIT THE CONTACT EMAIL FIRST -- it ships as CHANGE-ME@example.invalid so an
#    unedited copy fails loudly instead of registering a placeholder with ACME
kubectl apply -f cluster_base/cert-manager/clusterissuer-letsencrypt.yaml

# 3. load balancer controller
kubectl apply -k cluster_base/aws-load-balancer-controller
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
```

## Verifying IRSA actually works

Assumed credentials fail quietly — the pod runs and only errors when it first
calls AWS. To check directly:

```sh
kubectl -n cert-manager exec deploy/cert-manager -- \
  env | grep AWS_

kubectl -n cert-manager logs deploy/cert-manager | grep -i 'credential\|assume\|sts'
```

A `WebIdentityErr` or `InvalidIdentityToken` means the OIDC discovery documents
in the bucket do not match what the API server is issuing.

## Pinned versions

| Component | Version |
| --- | --- |
| cert-manager | `v1.21.2` |
| AWS Load Balancer Controller | `v3.5.0` |

Bump deliberately. These patches target resources by name, and upstream renaming
a Deployment or a container makes a strategic-merge patch a **silent no-op**
rather than an error. The LBC container is named `controller`, not
`aws-load-balancer-controller`. After any bump, rebuild and confirm the env vars
and volumes are still present.

The LBC patch replaces the container's `args` wholesale, because
strategic-merge has no merge key for a list of scalars — every argument the
controller needs is listed in the patch, including upstream's own.

## Known gaps

- **`--disable-restricted-sg-rules` is not set.** The controller expects to
  mutate node security groups, which Terraform owns. The existing NodePort rule
  (30000–32767 from the VPC CIDR) already admits ALB traffic, so that flag is
  worth considering — the exact spelling was not verified against v3.5.0.
- **Instance targets only.** Flannel pods hold overlay addresses, not VPC
  addresses, so `target-type: ip` cannot work. Ingresses must use
  `alb.ingress.kubernetes.io/target-type: instance`.
- **Nodes have no `providerID`.** Instance-mode target registration resolves
  nodes to EC2 instance IDs through it, and kubeadm leaves it unset without a
  cloud provider. The AWS cloud-controller-manager is still required before the
  controller can register targets.
