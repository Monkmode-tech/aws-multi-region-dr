###############################################################################
# AWS Backup: daily snapshots of everything tagged Backup=true, copied to a
# vault in the DR region.
#
# Why backups when the table already replicates? Replication faithfully
# copies a bad deploy, an accidental delete or ransomware encryption to the
# other region within a second. Point-in-time recovery (35 days) and these
# vaulted, cross-region copies are the "undo" for logical corruption.
#
# The DR vault has a Vault Lock (governance mode) so recovery points cannot
# be deleted early by anyone without the specific bypass permission.
###############################################################################

data "aws_partition" "current" {}

# Cross-region copy of DynamoDB backups needs AWS Backup's "advanced" DynamoDB
# features (independent encryption, copy, cold storage) turned on per region.
resource "aws_backup_region_settings" "primary" {
  count = var.manage_region_settings ? 1 : 0

  resource_type_opt_in_preference = {
    "DynamoDB" = true
  }

  resource_type_management_preference = {
    "DynamoDB" = true
  }
}

resource "aws_backup_region_settings" "dr" {
  count    = var.manage_region_settings ? 1 : 0
  provider = aws.dr

  resource_type_opt_in_preference = {
    "DynamoDB" = true
  }

  resource_type_management_preference = {
    "DynamoDB" = true
  }
}

resource "aws_backup_vault" "primary" {
  name          = "${var.name}-primary"
  kms_key_arn   = var.primary_kms_key_arn
  force_destroy = var.force_destroy
}

resource "aws_backup_vault" "dr" {
  provider = aws.dr

  name          = "${var.name}-dr"
  kms_key_arn   = var.dr_kms_key_arn
  force_destroy = var.force_destroy
}

# Governance mode: protects against accidental or malicious early deletion,
# but can still be removed by a principal with backup:DeleteBackupVaultLockConfiguration
# (compliance mode would make the lock - and the bill - permanent).
resource "aws_backup_vault_lock_configuration" "dr" {
  provider = aws.dr

  backup_vault_name  = aws_backup_vault.dr.name
  min_retention_days = 7
  max_retention_days = 120
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-daily"

  rule {
    rule_name         = "daily-with-dr-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.schedule
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = var.dr_retention_days
      }
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid = "UseRegionalVaultKeys"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = [var.primary_kms_key_arn, var.dr_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "kms" {
  name   = "vault-keys"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.kms.json
}

resource "aws_backup_selection" "tagged" {
  name         = "backup-tag"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = ["*"]

  condition {
    string_equals {
      key   = "aws:ResourceTag/Backup"
      value = "true"
    }
  }
}

# Tell someone when a backup or a cross-region copy fails.
resource "aws_backup_vault_notifications" "primary" {
  count = var.alerts_topic_arn == "" ? 0 : 1

  backup_vault_name   = aws_backup_vault.primary.name
  sns_topic_arn       = var.alerts_topic_arn
  backup_vault_events = ["BACKUP_JOB_FAILED", "COPY_JOB_FAILED", "RESTORE_JOB_COMPLETED"]
}
