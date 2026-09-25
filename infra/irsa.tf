# IRSA: IAM roles assumed by Kubernetes service accounts, via the cluster's own
# OIDC issuer hosted in the public bucket from s3.tf.
#
# Ordering: the provider can be created before the discovery documents exist --
# IAM verifies the endpoint's TLS certificate, not its content, and the S3 host
# serves TLS as soon as the bucket does. The documents only have to be in place
# before the first AssumeRoleWithWebIdentity call. They cannot exist until the
# cluster is up, so in practice this lands in a later apply than the cluster
# build; declaring it here just removes the manual aws-cli step.
#
# No thumbprint_list: for an S3-hosted JWKS endpoint AWS validates against its
# own trusted CA library and ignores configured thumbprints entirely.

resource "aws_iam_openid_connect_provider" "cluster" {
  url            = local.oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${var.name}-cluster-oidc"
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller service account role.
#
# Scopes the controller's permissions to one service account instead of every
# pod on the node, which is what the instance-role attachment in iam.tf does.
# Once this role is in use, drop aws_iam_role_policy_attachment.k8s_master_lbc
# and .node_lbc so the nodes stop carrying those permissions.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lbc_assume_role" {
  statement {
    sid     = "AssumeRoleWithClusterOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Pins the role to exactly one service account. Without the sub condition
    # any service account in the cluster could assume it.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.lbc_namespace}:${var.lbc_service_account}"]
    }

    # The projected token must carry the STS audience.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.name}-aws-load-balancer-controller"
  description        = "IRSA role for the AWS Load Balancer Controller service account"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json

  tags = {
    Name = "${var.name}-aws-load-balancer-controller"
  }
}

resource "aws_iam_role_policy_attachment" "lbc_irsa" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}
