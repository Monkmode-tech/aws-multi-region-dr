variable "name" {
  description = "Name prefix for vaults, plan and role."
  type        = string
}

variable "primary_kms_key_arn" {
  description = "KMS key for the primary-region vault."
  type        = string
}

variable "dr_kms_key_arn" {
  description = "KMS key for the DR-region vault."
  type        = string
}

variable "schedule" {
  description = "Backup schedule (AWS cron, UTC)."
  type        = string
  default     = "cron(0 5 * * ? *)"
}

variable "retention_days" {
  description = "Days to keep recovery points in the primary vault."
  type        = number
  default     = 14
}

variable "dr_retention_days" {
  description = "Days to keep copies in the DR vault (between the vault lock's 7 and 120)."
  type        = number
  default     = 14
}

variable "manage_region_settings" {
  description = "Turn on AWS Backup advanced DynamoDB features in both regions (needed for cross-region copy)."
  type        = bool
  default     = true
}

variable "alerts_topic_arn" {
  description = "SNS topic (primary region) for failed backup/copy jobs. Empty = none."
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete vaults that still hold recovery points (lab teardown)."
  type        = bool
  default     = true
}
