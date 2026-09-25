# Instance roles for the cluster: one for the worker nodes, one for the control
# plane. Separate roles so the master's permissions can grow (cloud-controller
# manager, EBS CSI driver, backups) without widening what the workers hold.
#
# The bastion deliberately gets neither -- it is not a cluster node.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Worker nodes.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name               = "${var.name}-k8s-node"
  description        = "k8s worker node role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.name}-k8s-node"
  }
}

# Lets kubelet and containerd authenticate to ECR. Flannel's image ships from
# ghcr.io, so this matters only for images hosted in your own ECR registry.
resource "aws_iam_role_policy_attachment" "node_ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name}-k8s-node"
  role = aws_iam_role.node.name

  tags = {
    Name = "${var.name}-k8s-node"
  }
}

# ---------------------------------------------------------------------------
# Control plane.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "k8s_master" {
  name               = "${var.name}-k8s-master"
  description        = "k8s control plane role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.name}-k8s-master"
  }
}

resource "aws_iam_role_policy_attachment" "k8s_master_ecr_read_only" {
  role       = aws_iam_role.k8s_master.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "k8s_master" {
  name = "${var.name}-k8s-master"
  role = aws_iam_role.k8s_master.name

  tags = {
    Name = "${var.name}-k8s-master"
  }
}

# ---------------------------------------------------------------------------
# S3 access. The control plane reads and writes; the workers only read.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "ListTheBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.main.arn]
  }

  statement {
    sid       = "ReadWriteObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectTagging", "s3:PutObject", "s3:PutObjectAcl"]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }

  # The control plane publishes its OIDC discovery document and JWKS here.
  statement {
    sid       = "ListTheOidcBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.oidc.arn]
  }

  # PutObjectAcl is granted in IAM, but note both buckets block public ACLs and
  # neither sets aws_s3_bucket_ownership_controls, so they keep the
  # BucketOwnerEnforced default and reject ACLs outright -- see README.
  statement {
    sid       = "WriteOidcObjects"
    effect    = "Allow"
    actions   = ["s3:GetObjectTagging", "s3:PutObject", "s3:PutObjectAcl"]
    resources = ["${aws_s3_bucket.oidc.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_access" {
  name        = "${var.name}-s3-access"
  description = "Application bucket read/write; OIDC bucket list and write"
  policy      = data.aws_iam_policy_document.s3_access.json
}

resource "aws_iam_role_policy_attachment" "k8s_master_s3_access" {
  role       = aws_iam_role.k8s_master.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# Application bucket only. The OIDC bucket is the control plane's alone: the
# master publishes the discovery documents there, and nothing on a worker needs
# S3 API access to that bucket -- it is world-readable over plain HTTPS.
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid       = "ListTheBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.main.arn]
  }

  statement {
    sid       = "ReadObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectTagging"]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }
}

resource "aws_iam_policy" "s3_read" {
  name        = "${var.name}-s3-read"
  description = "List the application bucket and get its objects"
  policy      = data.aws_iam_policy_document.s3_read.json
}

resource "aws_iam_role_policy_attachment" "node_s3_read" {
  role       = aws_iam_role.node.name
  policy_arn = aws_iam_policy.s3_read.arn
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller.
#
# policies/aws-load-balancer-controller-iam-policy.json is vendored verbatim
# from kubernetes-sigs/aws-load-balancer-controller (docs/install/iam_policy.json).
# There is no AWS-managed equivalent. Re-download it when upgrading the
# controller: new releases add actions.
#
# The policy itself stays: irsa.tf attaches it to the controller's own service
# account role, which is the scoped way to grant it.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller (vendored upstream policy)"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

# Commented out in favour of the IRSA role in irsa.tf. These attached the
# controller's permissions to the instance roles, so every pod on those nodes
# inherited the ability to create load balancers and mutate security groups.
#
# Uncomment only as a fallback if IRSA is not working yet -- and note the
# controller must then run hostNetwork: true, since imds_hop_limit = 1 keeps
# pods away from the instance role's credentials.
#
# resource "aws_iam_role_policy_attachment" "k8s_master_lbc" {
#   role       = aws_iam_role.k8s_master.name
#   policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
# }
#
# resource "aws_iam_role_policy_attachment" "node_lbc" {
#   role       = aws_iam_role.node.name
#   policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
# }
