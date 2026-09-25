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
#
# Gated on var.enable_oidc_provider, default false. IAM validates the issuer at
# CreateOpenIDConnectProvider, so the provider cannot be created until the
# discovery documents are actually in the bucket -- which needs a running
# cluster. Apply once with this false, let the master publish the documents,
# then set it true. The roles below are gated identically: their trust policies
# name the provider ARN.

resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.enable_oidc_provider ? 1 : 0

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
  count = var.enable_oidc_provider ? 1 : 0

  statement {
    sid     = "AssumeRoleWithClusterOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster[0].arn]
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
  count = var.enable_oidc_provider ? 1 : 0

  name               = "${var.name}-aws-load-balancer-controller"
  description        = "IRSA role for the AWS Load Balancer Controller service account"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role[0].json

  tags = {
    Name = "${var.name}-aws-load-balancer-controller"
  }
}

resource "aws_iam_role_policy_attachment" "lbc_irsa" {
  count = var.enable_oidc_provider ? 1 : 0

  role       = aws_iam_role.aws_load_balancer_controller[0].name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

# ---------------------------------------------------------------------------
# external-dns service account role.
#
# Same IRSA pattern as the load balancer controller above: the trust policy is
# pinned to one service account by the issuer's :sub condition, so only that
# service account's projected token can assume it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "external_dns_assume_role" {
  count = var.enable_oidc_provider ? 1 : 0

  statement {
    sid     = "AssumeRoleWithClusterOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.external_dns_namespace}:${var.external_dns_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Upstream's reference policy scopes the record actions to hostedzone/*; this
# narrows them to the one zone in route53.tf. ListHostedZones has no
# resource-level permissions, so it stays on "*" -- external-dns calls it to
# find the zone for a record, and without it the others are unreachable.
data "aws_iam_policy_document" "external_dns" {
  statement {
    sid    = "ManageRecordsInTheZone"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]

    resources = [aws_route53_zone.tp.arn]
  }

  statement {
    sid       = "DiscoverZones"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name        = "${var.name}-external-dns"
  description = "Manage record sets in the ${var.dns_zone_name} hosted zone"
  policy      = data.aws_iam_policy_document.external_dns.json
}

resource "aws_iam_role" "external_dns" {
  count = var.enable_oidc_provider ? 1 : 0

  name               = "${var.name}-external-dns"
  description        = "IRSA role for the external-dns service account"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role[0].json

  tags = {
    Name = "${var.name}-external-dns"
  }
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  count = var.enable_oidc_provider ? 1 : 0

  role       = aws_iam_role.external_dns[0].name
  policy_arn = aws_iam_policy.external_dns.arn
}

# ---------------------------------------------------------------------------
# cert-manager service account role (ACME DNS-01 solver).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cert_manager_assume_role" {
  count = var.enable_oidc_provider ? 1 : 0

  statement {
    sid     = "AssumeRoleWithClusterOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.cert_manager_namespace}:${var.cert_manager_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Follows cert-manager's documented Route 53 policy, with the record actions
# narrowed from hostedzone/* to the one zone in route53.tf.
data "aws_iam_policy_document" "cert_manager" {
  # Polling a change to completion. Change IDs are not predictable, so this
  # cannot be scoped further than change/*.
  statement {
    sid       = "PollChangeStatus"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  # The ForAllValues condition is upstream's, and worth keeping: DNS-01 only
  # ever writes _acme-challenge TXT records, so cert-manager cannot touch the
  # A/CNAME/NS records external-dns and the delegation rely on.
  statement {
    sid    = "WriteChallengeRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]

    resources = [aws_route53_zone.tp.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  # Needed only while the Issuer does not pin hostedZoneID; cert-manager uses it
  # to resolve a domain to its zone. Safe to drop once the Issuer names the zone.
  statement {
    sid       = "ResolveZoneByName"
    effect    = "Allow"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "cert_manager" {
  name        = "${var.name}-cert-manager"
  description = "ACME DNS-01 challenge records in the ${var.dns_zone_name} hosted zone"
  policy      = data.aws_iam_policy_document.cert_manager.json
}

resource "aws_iam_role" "cert_manager" {
  count = var.enable_oidc_provider ? 1 : 0

  name               = "${var.name}-cert-manager"
  description        = "IRSA role for the cert-manager service account"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume_role[0].json

  tags = {
    Name = "${var.name}-cert-manager"
  }
}

resource "aws_iam_role_policy_attachment" "cert_manager" {
  count = var.enable_oidc_provider ? 1 : 0

  role       = aws_iam_role.cert_manager[0].name
  policy_arn = aws_iam_policy.cert_manager.arn
}
