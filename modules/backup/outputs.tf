output "primary_vault" {
  description = "Primary-region backup vault name."
  value       = aws_backup_vault.primary.name
}

output "dr_vault" {
  description = "DR-region backup vault name (holds the cross-region copies)."
  value       = aws_backup_vault.dr.name
}

output "plan_id" {
  description = "Backup plan ID."
  value       = aws_backup_plan.this.id
}

output "role_arn" {
  description = "IAM role used by backup and restore jobs."
  value       = aws_iam_role.backup.arn
}
