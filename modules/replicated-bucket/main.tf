###############################################################################
# S3 Cross-Region Replication for the ledger's document store (receipts and
# nightly exports). Source in the primary region, replica in the DR region,
# each encrypted with its own regional KMS key. Optional Replication Time
# Control (RTC) adds a 15-minute replication SLA for an extra per-GB charge.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "primary" {}
data "aws_region" "dr" {
  provider = aws.dr
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  buckets = {
    source  = "${var.name}-${local.account_id}-${data.aws_region.primary.region}"
    replica = "${var.name}-${local.account_id}-${data.aws_region.dr.region}"
  }
}

#------------------------------------------------------------------------------
# Source bucket (primary region)
#------------------------------------------------------------------------------
resource "aws_s3_bucket" "source" {
  # checkov:skip=CKV_AWS_18: Access logging is a production follow-up; CloudTrail data events can cover it
  # checkov:skip=CKV2_AWS_62: Nothing consumes event notifications in this lab
  bucket        = local.buckets.source
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.source_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "tls_only_source" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "source" {
  bucket = aws_s3_bucket.source.id
  policy = data.aws_iam_policy_document.tls_only_source.json

  depends_on = [aws_s3_bucket_public_access_block.source]
}

#------------------------------------------------------------------------------
# Replica bucket (DR region)
#------------------------------------------------------------------------------
resource "aws_s3_bucket" "replica" {
  # checkov:skip=CKV_AWS_18: Access logging is a production follow-up; CloudTrail data events can cover it
  # checkov:skip=CKV2_AWS_62: Nothing consumes event notifications in this lab
  # checkov:skip=CKV_AWS_144: This IS the cross-region replica; replicating it again would loop
  provider = aws.dr

  bucket        = local.buckets.replica
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.dr

  bucket = aws_s3_bucket.replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.dr

  bucket = aws_s3_bucket.replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.replica_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider = aws.dr

  bucket                  = aws_s3_bucket.replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  provider = aws.dr

  bucket = aws_s3_bucket.replica.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "tls_only_replica" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.replica.arn, "${aws_s3_bucket.replica.arn}/*"]

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
}

resource "aws_s3_bucket_policy" "replica" {
  provider = aws.dr

  bucket = aws_s3_bucket.replica.id
  policy = data.aws_iam_policy_document.tls_only_replica.json

  depends_on = [aws_s3_bucket_public_access_block.replica]
}

#------------------------------------------------------------------------------
# Replication role + rule
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "replication_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = "${var.name}-s3-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    sid       = "ReadSourceConfig"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.source.arn]
  }

  statement {
    sid       = "ReadSourceObjects"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }

  statement {
    sid       = "WriteReplica"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${aws_s3_bucket.replica.arn}/*"]
  }

  statement {
    sid       = "DecryptSource"
    actions   = ["kms:Decrypt"]
    resources = [var.source_kms_key_arn]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.primary.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "EncryptReplica"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = [var.replica_kms_key_arn]

    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.dr.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "replication" {
  name   = "replicate-to-dr"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_s3_bucket_replication_configuration" "this" {
  bucket = aws_s3_bucket.source.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "everything-to-dr"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = var.replica_kms_key_arn
      }

      metrics {
        status = "Enabled"

        event_threshold {
          minutes = 15
        }
      }

      dynamic "replication_time" {
        for_each = var.enable_rtc ? [1] : []

        content {
          status = "Enabled"

          time {
            minutes = 15
          }
        }
      }
    }
  }

  # Replication requires versioning on both sides first.
  depends_on = [aws_s3_bucket_versioning.source, aws_s3_bucket_versioning.replica]
}
