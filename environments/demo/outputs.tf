output "api_url" {
  description = "Shared, failover-protected API URL."
  value       = "https://${local.fqdn}"
}

output "primary_api_host" {
  description = "Region-specific API hostname in the primary region (bypasses DNS failover)."
  value       = module.api_primary.execute_api_host
}

output "dr_api_host" {
  description = "Region-specific API hostname in the DR region (bypasses DNS failover)."
  value       = module.api_dr.execute_api_host
}

output "primary_function_name" {
  description = "Primary API Lambda (the game day throttles it to simulate a regional outage)."
  value       = module.api_primary.function_name
}

output "dr_function_name" {
  description = "DR API Lambda."
  value       = module.api_dr.function_name
}

output "table_name" {
  description = "DynamoDB global table name."
  value       = module.table.name
}

output "health_check_ids" {
  description = "Route 53 health checks (primary, secondary)."
  value       = module.dns.health_check_ids
}

output "zone_id" {
  description = "Hosted zone ID (the game day reads failover answers from its authoritative name servers)."
  value       = data.aws_route53_zone.this.zone_id
}

output "documents_buckets" {
  description = "S3 source and replica buckets."
  value = {
    source  = module.documents.source_bucket
    replica = module.documents.replica_bucket
  }
}

output "backup_vaults" {
  description = "AWS Backup vaults (primary, DR copy)."
  value = {
    primary = module.backup.primary_vault
    dr      = module.backup.dr_vault
  }
}

output "backup_role_arn" {
  description = "IAM role AWS Backup uses (the restore drill passes it to start-restore-job)."
  value       = module.backup.role_arn
}

output "dr_kms_key_arn" {
  description = "DR-region KMS key (restored tables are encrypted with it)."
  value       = module.kms_dr.key_arn
}

output "regions" {
  description = "Primary and DR regions."
  value = {
    primary = var.primary_region
    dr      = var.dr_region
  }
}
