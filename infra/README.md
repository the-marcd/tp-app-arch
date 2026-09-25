# infra

Flat Terraform (no modules) for a single AWS VPC with one public and one private subnet.

## Layout

| File | Contents |
| --- | --- |
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | AWS provider, region, default tags |
| `variables.tf` | Input variables |
| `vpc.tf` | AZ lookup, locals, the VPC |
| `subnets.tf` | Public and private subnets |
| `internet_gateway.tf` | Internet gateway attached to the VPC |
| `nat_gateway.tf` | NAT gateway + Elastic IP |
| `route_tables.tf` | Route tables, default routes, associations |
| `ec2.tf` | Ubuntu AMI lookup, EC2 instances |
| `security_groups.tf` | Security groups and all their rules |
| `vpc_endpoints.tf` | S3 gateway VPC endpoint |
| `iam.tf` | IAM roles, instance profiles, S3 policies |
| `s3.tf` | Application bucket and public OIDC bucket |
| `cloud-init/` | Control-plane bootstrap template |
| `policies/` | Vendored IAM policy JSON |
| `key_pairs.tf` | SSH key pairs for the bastion and the k8s nodes |
| `outputs.tf` | IDs of everything created |

## Addressing

| Resource | CIDR | AZ |
| --- | --- | --- |
| VPC | `172.31.0.0/22` (172.31.0.0 – 172.31.3.255) | — |
| Public subnet A | `172.31.0.0/24` | first |
| Private subnet A | `172.31.1.0/24` | first |
| Public subnet B | `172.31.2.0/24` | second |
| Private subnet B | `172.31.3.0/24` | second |

The `/22` is now fully allocated.

Two AZs because an ALB requires subnets in at least two. The AZ-a resources keep
the short names `aws_subnet.public` / `aws_subnet.private` so existing references
stay valid; the AZ-b ones are `public_b` / `private_b`.

Both public subnets share the public route table (`0.0.0.0/0` → internet
gateway) and both private subnets share the private one (`0.0.0.0/0` → NAT
gateway). The NAT gateway lives in public subnet A only, so AZ-b egress crosses
availability zones: cross-AZ data charges, and an AZ-a failure takes out egress
for both. A second NAT gateway and a per-AZ private route table would fix that,
at another hourly charge.

All four subnets carry the AWS Load Balancer Controller's discovery tags:

| Tag | Value | On |
| --- | --- | --- |
| `kubernetes.io/cluster/<cluster_name>` | `shared` | all four |
| `kubernetes.io/role/elb` | `1` | public subnets |
| `kubernetes.io/role/internal-elb` | `1` | private subnets |

`cluster_name` defaults to `var.name` and must match the controller's
`--cluster-name` flag.

## NAT gateway

Gated on `enable_nat_gateway`, **default `true`**. It covers the NAT gateway, its
Elastic IP and the private subnet's `0.0.0.0/0` route. On by default because the
private subnet has no other egress — without it the cluster cannot pull images or
packages.

It bills hourly plus per-GB for as long as it exists, so turning it off is the
single biggest saving while the environment is idle:

```sh
terraform apply -var 'enable_nat_gateway=false'
```

## Compute

| Instance | Type | Arch | Subnet | Root volume |
| --- | --- | --- | --- | --- |
| `bastion_ec2` | `t4g.nano` | arm64 (Graviton) | public | 10 GiB |
| `k8s_master` | `t4g.medium` | arm64 (Graviton) | private | 20 GiB |
| `k8s_worker` (×N) | `t4g.small` | arm64 (Graviton) | private | 20 GiB |

The workers are a `count`ed resource sized by `k8s_worker_count`, which
**defaults to `0`** — an apply with no overrides brings up the bastion and the
control plane only. Set it to bring workers up:

```sh
terraform apply -var 'k8s_worker_count=2'
```

Both run Ubuntu (`ubuntu_version`, default `26.04`) on encrypted gp3 root
volumes. Both are Graviton, so a single arm64 lookup, `data.aws_ami.ubuntu`,
serves them both; moving either to an x86_64 instance type means adding an
amd64 lookup back and pointing that instance's `ami` at it.

The AMI is resolved at plan time from Canonical's published images rather than
pinned, so a later apply can pick up a newer image and replace the instances.
Pin
`ami` to a literal ID if that matters.

### Access

Two key pairs, in `key_pairs.tf`:

| Key pair | Installed on | Public key file from |
| --- | --- | --- |
| `<name>-bastion` | `bastion_ec2` | `bastion_public_key_path` |
| `<name>-k8s` | `k8s_master` and every `k8s_worker` | `k8s_public_key_path` |

Both variables are required and take a **path to a `.pub` file**, not the key
text. Terraform reads only the public half, so the private keys cannot end up
in `terraform.tfstate`. Generate them yourself:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/tp-app-bastion -C tp-app-bastion
ssh-keygen -t ed25519 -f ~/.ssh/tp-app-k8s     -C tp-app-k8s
```

then point the variables at the `.pub` files, e.g. in a `terraform.tfvars`:

```hcl
bastion_public_key_path = "~/.ssh/tp-app-bastion.pub"
k8s_public_key_path     = "~/.ssh/tp-app-k8s.pub"
```

A leading `~` is expanded, and the trailing newline `ssh-keygen` writes is
stripped. Any OpenSSH public key type works — `ssh-rsa`, `ssh-ed25519`,
`ecdsa-sha2-*`, and the `sk-*@openssh.com` FIDO types.

The two failure modes report separately, which matters when something is wrong:

- **Path wrong or unreadable** — the `file()` call in `locals` fails with
  Terraform's own error naming the path (`no file exists at "..."`).
- **File is not a public key** — a `lifecycle` precondition on each key pair
  catches it, so pointing at a *private* key fails the plan rather than sending
  it to AWS.

Quote nothing when answering an interactive variable prompt: Terraform takes
the literal characters, so `"~/.ssh/key.pub"` with quotes becomes part of the
path and will not resolve.

`bastion_ec2`'s group accepts SSH from the CIDRs in `bastion_ssh_cidrs`
(default `47.197.109.105/32`) and allows all egress. That is the only way into
the environment — the k8s nodes accept SSH from the bastion's security group
alone, so everything reaches them through the bastion.

Widen or replace the list to add more operators:

```hcl
bastion_ssh_cidrs = ["47.197.109.105/32", "203.0.113.0/24"]
```

## Control-plane bootstrap

`k8s_master` carries `user_data` rendered from
`cloud-init/k8smaster.cloud-config.yaml.tftpl`. It installs `git`,
`python3-debian` and `python3-boto3`, then uses cloud-init's native `ansible`
module to run `ansible-pull` against `ansible_repo_url` (default
`https://github.com/the-marcd/tp-app-arch.git`) and execute
`k8smaster_playbook` (default `systems/k8smaster.yml`).

Three behaviours this depends on, each verified upstream rather than assumed:

- `ansible-pull` with no `--inventory` defaults to `-i localhost,` and limits to
  `localhost,<hostname>,127.0.0.1`, so the playbook's `hosts: "*"` matches.
- `package_update_upgrade_install` runs before `ansible` in
  `cloud_final_modules`, so those three packages are present before the pull.
- `install_method: distro` with `package_name: ansible` installs the full
  `ansible` package, not `ansible-core` — required because the roles use the
  `ansible.posix` and `amazon.aws` collections, which only the full package
  bundles.

**`user_data_replace_on_change = true`.** user_data only executes on first boot,
so editing the template is meaningless on a live instance. With this set, a
template change shows up in the plan as an instance replacement instead of
silently doing nothing. It also means adding this to an already-running master
replaces it.

The repo must be reachable unauthenticated from the private subnet through the
NAT gateway — `ansible-pull` runs before anything is configured.

Output lands in `/var/log/cloud-init-output.log`.

## Cluster firewall rules

`security_groups.tf` holds the groups and every rule. Rules are standalone
`aws_vpc_security_group_*_rule` resources rather than inline blocks, because the
master and worker groups reference each other and inline rules would deadlock
Terraform's dependency graph.

Ports follow the supplied port table.

**Inbound to `bastion_ec2`:**

| Port | Protocol | Source | Component |
| --- | --- | --- | --- |
| 22 | TCP | `bastion_ssh_cidrs` | SSH |

**Inbound to `k8s_master`:**

| Port | Protocol | Source | Component |
| --- | --- | --- | --- |
| 22 | TCP | bastion SG | SSH |
| 6443 | TCP | worker SG, bastion SG | kube-apiserver |
| 2379–2380 | TCP | master SG (self) | etcd client + peer |
| 10250 | TCP | master SG (self) | kubelet API |
| 10257 | TCP | master SG (self) | kube-controller-manager |
| 10259 | TCP | master SG (self) | kube-scheduler |

**Inbound to `k8s_worker`:**

| Port | Protocol | Source | Component |
| --- | --- | --- | --- |
| 22 | TCP | bastion SG | SSH |
| 10250 | TCP | master SG | kubelet API |
| 10256 | TCP | worker SG (self) | kube-proxy health endpoint |
| 30000–32767 | TCP **and** UDP | VPC CIDR | NodePort services |

All three groups allow unrestricted egress.

### Pod network: Flannel (VXLAN backend)

| Port | Protocol | Source | Destination |
| --- | --- | --- | --- |
| 8472 | UDP | worker SG | master SG |
| 8472 | UDP | master SG (self) | master SG |
| 8472 | UDP | master SG | worker SG |
| 8472 | UDP | worker SG (self) | worker SG |

Flannel encapsulates pod traffic in VXLAN, so what crosses the wire is
node-IP to node-IP on UDP 8472. Pod addresses live inside the tunnel and are
never evaluated by a security group — which is why one UDP port is enough,
where the AWS VPC CNI would have needed an all-protocol node-to-node allow.

Every node must reach every other node, hence both directions plus each group
to itself.

#### Matching cluster configuration

- `kubeadm init --pod-network-cidr=10.244.0.0/16` (Flannel's default). It does
  not overlap the VPC's `172.31.0.0/22`, so the overlay and the VPC can coexist.
- These rules assume the **default VXLAN backend**. `host-gw` would need no UDP
  port but does require disabling the EC2 source/destination check on every
  node and is not configured here. WireGuard backend would need UDP 51820–51821
  instead.
- Max pods per node is no longer bounded by ENI limits — pods draw from the
  overlay, not from VPC addresses. The 11-pod ceiling on `t4g.small` that the
  VPC CNI imposed does not apply.

## Cluster IAM

`iam.tf` defines two roles, each with its own instance profile of the same
name, both assumed by `ec2.amazonaws.com`:

| Role / profile | Attached to | Policies |
| --- | --- | --- |
| `<name>-k8s-master` | `k8s_master` | `AmazonEC2ContainerRegistryReadOnly`, `<name>-s3-access` |
| `<name>-k8s-node` | every `k8s_worker` | `AmazonEC2ContainerRegistryReadOnly`, `<name>-s3-read` |
| `<name>-aws-load-balancer-controller` | the controller's service account, via IRSA | `<name>-aws-load-balancer-controller` |

They are split so the control plane's permissions can grow — cloud-controller
manager, EBS CSI driver, etcd backups to S3 — without widening what the workers
hold.

`AmazonEC2ContainerRegistryReadOnly` lets kubelet and containerd authenticate
to ECR. Flannel's image ships from `ghcr.io`, so this matters only for images
hosted in your own ECR registry.

The two S3 policies differ only in write access:

| Policy | Role | Bucket | Actions |
| --- | --- | --- | --- |
| `<name>-s3-access` | master | application | `s3:ListBucket`; `s3:GetObject`, `s3:GetObjectTagging`, `s3:PutObject`, `s3:PutObjectAcl` |
| `<name>-s3-access` | master | OIDC | `s3:ListBucket`; `s3:GetObjectTagging`, `s3:PutObject`, `s3:PutObjectAcl` |
| `<name>-s3-read` | workers | application | `s3:ListBucket`; `s3:GetObject`, `s3:GetObjectTagging` |

Every statement is scoped to a named bucket — `ListBucket` on the bucket ARN,
object actions on `<arn>/*`.

`s3:GetObjectTagging` accompanies every object action.
`amazon.aws.s3_object` reads object tags when deciding whether an object needs
updating, so a put or get can fail with `AccessDenied` on the tagging call even
when the object action itself is allowed.

**The OIDC bucket is the control plane's alone.** The worker role has no
statement naming it at all — the master publishes the discovery documents, and
nothing on a worker needs S3 API access to that bucket, which is world-readable
over plain HTTPS anyway.

**`s3:PutObjectAcl` is granted in IAM but will not work against either bucket as
configured.** Both set `block_public_acls` and `ignore_public_acls`, and neither
declares `aws_s3_bucket_ownership_controls`, so both keep the current S3 default
of `BucketOwnerEnforced` — which disables ACLs entirely and makes any
`PutObjectAcl` call fail with `AccessControlListNotSupported`, whatever IAM
says. Making it usable means adding an ownership-controls resource set to
`ObjectWriter` and relaxing the public-ACL blocks, which is a bucket-level
decision rather than an IAM one. Public reads on the OIDC bucket already come
from its bucket policy and need no ACL. The master's OIDC grant is write-only by design:
it publishes the discovery documents, and reading them back is what the public
bucket policy is for.

`AmazonEKS_CNI_Policy` is no longer attached anywhere. It existed for the AWS
VPC CNI's ipamd; Flannel makes no EC2 API calls, so nothing needs permission to
create or delete network interfaces.

The bastion deliberately gets no instance profile — it is not a cluster node.

## AWS Load Balancer Controller

The Terraform side is in place: two AZs, the discovery tags above, and the
upstream IAM policy attached to both cluster roles.

`policies/aws-load-balancer-controller-iam-policy.json` is vendored verbatim
from `kubernetes-sigs/aws-load-balancer-controller`
(`docs/install/iam_policy.json`) — 16 statements, 80 actions across `ec2`,
`elasticloadbalancing`, `acm`, `iam`, `cognito-idp`, `shield`, `waf-regional`
and `wafv2`. There is no AWS-managed equivalent. **Re-download it when you
upgrade the controller**; new releases add actions.

It is attached to `<name>-k8s-master` and `<name>-k8s-node` because IRSA needs
an OIDC provider this self-managed cluster does not have, and EKS Pod Identity
is unavailable outside EKS ("Kubernetes clusters that you create and run on
Amazon EC2" are explicitly excluded upstream).

The controller's permissions no longer sit on the instance roles: the
`k8s_master_lbc` and `node_lbc` attachments are **commented out** in `iam.tf` in
favour of the IRSA role in `irsa.tf`. The policy itself remains, attached to the
service account role instead.

Uncomment them only as a fallback if IRSA is not yet working — and note the
controller must then run `hostNetwork: true`, because `imds_hop_limit = 1` keeps
pods away from the instance role's credentials.

### IMDS lockdown

All three instances set `metadata_options`:

| Setting | Value | Why |
| --- | --- | --- |
| `http_tokens` | `required` | IMDSv2 only; blocks the SSRF-style v1 GET |
| `http_put_response_hop_limit` | `var.imds_hop_limit` (default `1`) | pod traffic crosses the Flannel bridge to reach `169.254.169.254`, so one hop too many — pods cannot read instance-role credentials |
| `http_endpoint` | `enabled` | the node itself still needs IMDS |
| `instance_metadata_tags` | `enabled` | instance tags readable from IMDS |

**Consequence:** any pod that genuinely needs the instance role must run with
`hostNetwork: true` — the AWS Load Balancer Controller among them. If a
workload starts failing with credential or metadata timeouts, this is why;
raise `imds_hop_limit` to `2` to undo it.

### Still required, outside Terraform

- **`providerID` on every Node.** Instance-mode target registration resolves
  nodes to EC2 instance IDs through it, and kubeadm leaves it unset without a
  cloud provider. This means running the AWS cloud-controller-manager:
  `--cloud-provider=external` on the kubelets and control plane, plus its own
  IAM policy.
- **`target-type: instance`, not `ip`.** Flannel's pods sit at `10.244.0.0/16`
  inside a VXLAN tunnel; the controller's docs require pods to hold VPC subnet
  IPs for IP targets. Traffic therefore goes ALB → NodePort → kube-proxy → pod.
  Use `externalTrafficPolicy: Local` if you need client IPs.
- **cert-manager**, if installing from YAML manifests. The Helm chart handles
  the webhook certificates itself.
- **Controller flags:** `--cluster-name` (matching `cluster_name`), plus
  `--aws-vpc-id` and `--aws-region` unless you rely on IMDSv2.
- **Consider `--disable-restricted-sg-rules`.** The controller expects to mutate
  node security groups; Terraform owns them here, and the existing NodePort rule
  (30000–32767 from the VPC CIDR) already admits ALB traffic.

## IRSA

`irsa.tf` registers the cluster's own OIDC issuer with IAM and defines a role
the controller's service account can assume directly, instead of inheriting the
node's.

**`aws_iam_openid_connect_provider.cluster`** — `url` is the OIDC bucket's
regional domain over HTTPS, `client_id_list` is `["sts.amazonaws.com"]`. No
`thumbprint_list`: for an S3-hosted JWKS endpoint AWS validates against its own
trusted CA library and ignores configured thumbprints entirely.

**`aws_iam_role.external_dns`** — same pattern, pinned to
`system:serviceaccount:<external_dns_namespace>:<external_dns_service_account>`
(defaults `kube-system` / `external-dns`). Its policy is narrower than
upstream's reference: the record actions are scoped to this zone's ARN rather
than `hostedzone/*`.

| Statement | Actions | Resource |
| --- | --- | --- |
| `ManageRecordsInTheZone` | `route53:ChangeResourceRecordSets`, `ListResourceRecordSets`, `ListTagsForResources` | the `tp.darcsaint.net` zone ARN |
| `DiscoverZones` | `route53:ListHostedZones` | `*` |

`ListHostedZones` has no resource-level permissions in IAM, so it cannot be
scoped — external-dns calls it to map a record name onto a zone, and the other
actions are unreachable without it.

**`aws_iam_role.cert_manager`** — same pattern, pinned to
`system:serviceaccount:<cert_manager_namespace>:<cert_manager_service_account>`
(defaults `cert-manager` / `cert-manager`). Its policy follows cert-manager's
documented Route 53 solver policy, with the record actions narrowed to this
zone:

| Statement | Actions | Resource |
| --- | --- | --- |
| `PollChangeStatus` | `route53:GetChange` | `arn:aws:route53:::change/*` |
| `WriteChallengeRecords` | `route53:ChangeResourceRecordSets`, `ListResourceRecordSets` | the zone ARN, **TXT records only** |
| `ResolveZoneByName` | `route53:ListHostedZonesByName` | `*` |

Two constraints worth keeping in mind. `GetChange` cannot be scoped below
`change/*` because change IDs are not predictable. And the record statement
carries upstream's condition:

```json
"ForAllValues:StringEquals": {
  "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
}
```

which is the reason cert-manager and external-dns can share a zone safely —
cert-manager can only write the `_acme-challenge` TXT records, never the
A/CNAME/NS records external-dns and the delegation depend on.

`ResolveZoneByName` can be dropped once the `Issuer`/`ClusterIssuer` pins
`hostedZoneID`; it exists only so cert-manager can map a domain to its zone.

**`aws_iam_role.aws_load_balancer_controller`** — trust policy on
`sts:AssumeRoleWithWebIdentity`, federated to that provider, with two
`StringEquals` conditions:

| Condition key | Value |
| --- | --- |
| `<issuer-host>:sub` | `system:serviceaccount:kube-system:aws-load-balancer-controller` |
| `<issuer-host>:aud` | `sts.amazonaws.com` |

The `sub` condition is what pins the role to one service account; without it any
service account in the cluster could assume it. Namespace and name come from
`lbc_namespace` and `lbc_service_account`. The vendored controller policy is
attached to this role as well as to the instance roles.

### Ordering — this is a two-phase apply

Gated on `enable_oidc_provider`, **default `false`**, which also gates the three
IRSA roles and their attachments, since their trust policies name the provider's
ARN.

IAM validates the issuer during `CreateOpenIDConnectProvider`: it fetches the
discovery document, so the provider cannot be created until the control plane has
actually published one to the OIDC bucket. That needs a running cluster, which
needs this configuration applied. Hence:

```sh
terraform apply                                  # phase 1: everything else
# master boots, runs kubeadm init, publishes the OIDC documents to the bucket
terraform apply -var 'enable_oidc_provider=true'  # phase 2: provider + IRSA roles
```

With the flag off, `cluster_oidc_provider_arn` and the three `*_role_arn`
outputs are `null`.

### Wiring it to the controller

No `amazon-eks-pod-identity-webhook` is needed for a single workload. Set these
on the controller's pod spec or Helm values, using the
`aws_load_balancer_controller_role_arn` output:

```yaml
serviceAccount:
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: <aws_load_balancer_controller_role_arn>
```

Outside EKS that annotation is inert, so also project the token and set the SDK
environment variables directly — `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`,
and a `serviceAccountToken` volume with `audience: sts.amazonaws.com`.

## DNS

`route53.tf` creates the public hosted zone `dns_zone_name`, default
`tp.darcsaint.net`. Records in it are written by external-dns using the IRSA
role above.

### Delegation is not automatic

`tp.darcsaint.net` is a subdomain, so this zone resolves only once the parent
`darcsaint.net` zone delegates to it. Terraform creates the zone and its four
name servers but **cannot** create that delegation — the parent zone is not
managed here.

After applying, take the `dns_zone_name_servers` output and create a matching
`NS` record set for `tp` in the parent zone. Until then the zone exists, and
external-dns will happily write records into it, but nothing on the internet
resolves them.

If `darcsaint.net` turns out to live in this same AWS account, the delegation
can be managed here too with an `aws_route53_record` of type `NS` against the
parent zone — worth doing, since it keeps the two in sync.

## S3 buckets

`s3.tf` creates one bucket, named `<name>-<account id>` unless you set
`s3_bucket_name` (bucket names are globally unique, hence the account suffix).

- **SSE-S3** (`AES256`) applied by default to every object, with an S3 Bucket
  Key enabled to cut per-object encryption calls.
- **Public access blocked** on all four settings. Not requested, but the bucket
  is private by intent and this stops a stray ACL or bucket policy from opening
  it. Remove the `aws_s3_bucket_public_access_block` if you need public objects.

No versioning, lifecycle rules or access logging are configured.

### OIDC bucket — public by design

A second bucket, `<name>-oidc-<account id>` (override with `oidc_bucket_name`),
holds the cluster's OpenID discovery document and JWKS for IRSA. AWS STS fetches
these anonymously, so the bucket **must** be publicly readable.

What "public" means here, precisely:

| | |
| --- | --- |
| Granted to `*` | `s3:GetObject` on `<arn>/*` only |
| Not granted | `s3:ListBucket` — the bucket cannot be enumerated |
| Not granted | any write action |
| ACLs | still blocked (`block_public_acls`, `ignore_public_acls`) |
| Bucket policy | permitted (`block_public_policy = false`, `restrict_public_buckets = false`) |

Only a bucket policy can open this bucket, and it opens exactly one action.
Both documents are public by nature — a JWKS contains public keys.

No `aws_s3_bucket_server_side_encryption_configuration` is declared for this
bucket, unlike the application bucket. S3 still applies its account-level
default (SSE-S3) to objects at rest; dropping the explicit block just means
Terraform does not manage the setting.

The `oidc_issuer_url` output gives the value for the kube-apiserver's
`--service-account-issuer` flag and the IAM OIDC provider URL.

## VPC endpoint

One gateway endpoint, `com.amazonaws.<region>.s3`, attached to the private route
table. Gateway endpoints have no ENI, no security group and no hourly charge;
they keep the private subnet's S3 traffic — including the control plane writing
discovery documents to the OIDC bucket — off the NAT gateway's per-GB billing.

The ECR interface endpoints (`ecr.api`, `ecr.dkr`) and their security group were
removed. They were added for the AWS VPC CNI, whose image lives in ECR; with
Flannel nothing in this build pulls from ECR, and they billed hourly per AZ
regardless. Everything the cluster pulls — `registry.k8s.io`, `ghcr.io`,
`pkgs.k8s.io`, the Ubuntu archives — goes out through the NAT gateway.

## Usage

```sh
terraform init
terraform plan
terraform apply
```

Override defaults with a `*.tfvars` file or `-var` flags, e.g.:

```sh
terraform apply -var 'region=us-west-2' -var 'name=tp-app-dev'
```

Both subnets default to the first available AZ in the region; set
`public_subnet_az` / `private_subnet_az` to place them explicitly.

State is local by default — add a backend block to `versions.tf` before using
this anywhere shared.
