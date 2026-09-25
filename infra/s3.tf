# Application bucket.
#
# The name is account-suffixed because S3 bucket names are globally unique;
# override var.s3_bucket_name to pick your own.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "main" {
  bucket = coalesce(var.s3_bucket_name, "${var.name}-${data.aws_caller_identity.current.account_id}")

  tags = {
    Name = var.name
  }
}

# SSE-S3: S3-managed keys, applied to every object at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

# Not requested, but the bucket is private-by-intent: this keeps a stray ACL or
# bucket policy from making it public. Remove if you need public objects.
resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# OIDC discovery bucket -- deliberately public.
#
# IRSA needs the cluster's OpenID discovery document and JWKS fetchable over
# HTTPS by AWS STS, which is an unauthenticated caller. Only s3:GetObject is
# granted to everyone, and only on objects: the bucket cannot be listed, and
# nothing anonymous can write. Both documents are public by design -- a JWKS
# holds public keys.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "oidc" {
  bucket = coalesce(var.oidc_bucket_name, "${var.name}-oidc-${data.aws_caller_identity.current.account_id}")

  tags = {
    Name = "${var.name}-oidc"
  }
}

# ACLs stay blocked; only the bucket policy below may grant public access.
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "oidc_public_read" {
  statement {
    sid    = "PublicReadDiscoveryDocuments"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.oidc.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc_public_read.json

  # The public access block must permit a public policy before one is attached.
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}
