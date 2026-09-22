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
| `nat_gateway.tf` | Optional NAT gateway + Elastic IP (off by default) |
| `route_tables.tf` | Route tables, default routes, associations |
| `ec2.tf` | Ubuntu AMI lookup, EC2 instances |
| `security_groups.tf` | Security groups and all their rules |
| `vpc_endpoints.tf` | ECR (api + dkr) and S3 VPC endpoints |
| `iam.tf` | Node IAM role, VPC CNI policy, instance profile |
| `key_pairs.tf` | SSH key pairs for the bastion and the k8s nodes |
| `outputs.tf` | IDs of everything created |

## Addressing

| Resource | CIDR |
| --- | --- |
| VPC | `172.31.0.0/22` (172.31.0.0 – 172.31.3.255) |
| Public subnet | `172.31.0.0/24` |
| Private subnet | `172.31.1.0/24` |

`172.31.2.0/23` is left free for future subnets.

The public subnet's route table sends `0.0.0.0/0` to the internet gateway.

## NAT gateway

The NAT gateway is written but not provisioned. It is gated behind
`enable_nat_gateway`, which defaults to `false`:

```sh
terraform apply -var 'enable_nat_gateway=true'
```

With the flag off, neither the NAT gateway, its Elastic IP, nor the private
default route exist, and the private subnet has no outbound internet path.
Turning it on creates all three and costs an hourly charge plus per-GB
processing for as long as it exists. The `nat_gateway_id` and
`nat_gateway_public_ip` outputs are `null` while it is off.

## Compute

| Instance | Type | Arch | Subnet | Root volume |
| --- | --- | --- | --- | --- |
| `bastion_ec2` | `t4g.nano` | arm64 (Graviton) | public | 10 GiB |
| `k8s_master` | `t4g.medium` | arm64 (Graviton) | private | 20 GiB |
| `k8s_worker` (×2) | `t4g.small` | arm64 (Graviton) | private | 20 GiB |

The workers are a `count`ed resource sized by `k8s_worker_count` (default `2`).

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

| Key pair | Installed on | Public key from |
| --- | --- | --- |
| `<name>-bastion` | `bastion_ec2` | `bastion_public_key` |
| `<name>-k8s` | `k8s_master` and every `k8s_worker` | `k8s_public_key` |

Both variables are required and take **public** key material in
`authorized_keys` format. Terraform never sees the private halves, so they
cannot end up in `terraform.tfstate`. Generate them yourself:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/tp-app-bastion -C tp-app-bastion
ssh-keygen -t ed25519 -f ~/.ssh/tp-app-k8s     -C tp-app-k8s
```

then pass the `.pub` contents in, e.g. in a `terraform.tfvars`:

```hcl
bastion_public_key = "ssh-ed25519 AAAA... tp-app-bastion"
k8s_public_key     = "ssh-ed25519 AAAA... tp-app-k8s"
```

`bastion_ec2`'s group allows all egress and **no ingress** — so the keys are in
place, but nothing can reach the bastion, and therefore nothing can reach the
nodes through it, until an ingress rule is added.

## Cluster firewall rules

`security_groups.tf` holds the groups and every rule. Rules are standalone
`aws_vpc_security_group_*_rule` resources rather than inline blocks, because the
master and worker groups reference each other and inline rules would deadlock
Terraform's dependency graph.

Ports follow the supplied port table.

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

### Pod network (AWS VPC CNI)

The AWS VPC CNI assigns pods real VPC addresses on secondary ENIs, and those
ENIs inherit their node's security group. Pod traffic is **not encapsulated**,
so it is evaluated against these groups on whatever port the workload happens
to use. There is no overlay port to open — instead the node groups must admit
each other wholesale:

| Destination | Source | Protocol |
| --- | --- | --- |
| master SG | worker SG | all |
| master SG | master SG (self) | all |
| worker SG | master SG | all |
| worker SG | worker SG (self) | all |

This is broad by design and is the trade-off the VPC CNI makes: any pod can
reach any port on any node or pod in the cluster. Tightening it needs security
groups for pods, which is an EKS-only feature and not available on a
self-managed cluster.

These rules subsume the narrower master↔worker port rules in the tables above.
Those are kept because they record which component needs which port; delete
them if you would rather the group read as exactly what it enforces.

No Flannel/Calico/Cilium rules are present, and none are needed — those plugins
are not in use.

## Node IAM

`iam.tf` defines one role, `<name>-k8s-node`, assumed by EC2 and attached to
`k8s_master` and both `k8s_worker` nodes through the `<name>-k8s-node` instance
profile. The bastion deliberately gets no profile — it is not a cluster node.

Two AWS-managed policies:

- **`AmazonEKS_CNI_Policy`** — the ENI create/attach/detach/address permissions
  ipamd needs.
- **`AmazonEC2ContainerRegistryReadOnly`** — so kubelet and containerd can
  authenticate to ECR and actually pull through the endpoints below. Without it
  the endpoints resolve but every pull is denied.

## VPC endpoints

`vpc_endpoints.tf` gives the private subnet a path to ECR without a NAT
gateway:

| Endpoint | Type | Attached to |
| --- | --- | --- |
| `com.amazonaws.<region>.ecr.api` | Interface | private subnet |
| `com.amazonaws.<region>.ecr.dkr` | Interface | private subnet |
| `com.amazonaws.<region>.s3` | Gateway | private route table |

All three are needed for an ECR pull: the two interface endpoints for the
registry API and the Docker registry protocol, and S3 because ECR stores image
layers there. The interface endpoints sit behind their own security group,
which allows 443 from the master and worker groups only.

The two interface endpoints bill hourly per AZ plus per-GB; the S3 gateway
endpoint is free.

### What the endpoints do *not* cover

They reach **private ECR only** — e.g. the EKS-hosted VPC CNI image at
`602401143452.dkr.ecr.<region>.amazonaws.com`. Still unreachable from the
private subnet while `enable_nat_gateway` is `false`:

- `registry.k8s.io` — the kube-apiserver, etcd, CoreDNS and kube-proxy images
  that `kubeadm init` pulls
- `pkgs.k8s.io` and the Ubuntu archives — the `kubeadm`, `kubelet`, `kubectl`
  and `containerd` packages
- `public.ecr.aws`, Docker Hub, and everything else

So these endpoints are sufficient for the VPC CNI image but **not** sufficient
to build the cluster. Either turn on `enable_nat_gateway` for the build, or
mirror the upstream images into your own ECR registry first.

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
