variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "ledger-dr"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "primary_region" {
  description = "Region that serves traffic while healthy."
  type        = string
  default     = "us-east-2"
}

variable "dr_region" {
  description = "Warm-standby region. Keep us-east-1: Route 53 health-check metrics (and their alarms) live there."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain with a public Route 53 hosted zone in this account (e.g. example.com)."
  type        = string
}

variable "api_subdomain" {
  description = "Subdomain for the failover API; the full name is <api_subdomain>.<domain_name>."
  type        = string
  default     = "ledger"
}

variable "alert_email" {
  description = "Email for alarms in both regions. Empty = no subscription."
  type        = string
  default     = ""
}

variable "deletion_protection" {
  description = "Protect the global table from deletion. Set false (and apply) before terraform destroy."
  type        = bool
  default     = true
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency per regional API Lambda (-1 = unreserved; e.g. 10 once the account quota is 1,000)."
  type        = number
  default     = -1
}

variable "enable_s3_rtc" {
  description = "S3 Replication Time Control (15-minute SLA; extra per-GB cost)."
  type        = bool
  default     = false
}
