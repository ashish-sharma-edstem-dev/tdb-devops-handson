data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = coalesce(var.bucket_name, "tdb-bookings-tfstate-${data.aws_caller_identity.current.account_id}")
}

# Customer-managed key, so access to state needs both S3 and KMS permissions, and every decrypt is in CloudTrail.
data "aws_iam_policy_document" "state_key" {
  #checkov:skip=CKV_AWS_109:Key policy: "*" in a key policy means this key only, and admin rights stay with the account root so IAM policies govern access.
  #checkov:skip=CKV_AWS_111:Key policy: "*" in a key policy means this key only; write access is still granted through IAM in this account.
  #checkov:skip=CKV_AWS_356:Key policy: "*" in a key policy means this key only, not every resource.
  statement {
    sid       = "AccountAdministersKeyThroughIAM"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state for tdb-bookings"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json
}

resource "aws_kms_alias" "state" {
  name          = var.kms_alias
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:Cross-region replication not used: versioning + the 30-day KMS deletion window cover the realistic loss cases (bad apply, deleted object) for a single-region service.
  #checkov:skip=CKV_AWS_18:Server access logs not enabled: CloudTrail data events are the audit source for state access; a separate log bucket is not worth it for one small bucket.
  #checkov:skip=CKV2_AWS_62:No consumer for event notifications on state writes.
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules on an unversioned bucket would not keep anything to expire.
  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # The S3 backend with `encrypt = true` but no `kms_key_id` sends AES256 explicitly, which would override the
  # bucket's KMS default. Refuse that so a misconfigured backend fails loudly instead of writing weaker state.
  statement {
    sid       = "DenySSES3Uploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # Apply the public access block first, so the policy is never evaluated on a bucket without it.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
