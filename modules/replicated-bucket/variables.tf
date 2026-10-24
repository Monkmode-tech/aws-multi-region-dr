variable "name" {
  description = "Bucket name prefix; account ID and region are appended."
  type        = string
}

variable "source_kms_key_arn" {
  description = "KMS key in the primary region."
  type        = string
}

variable "replica_kms_key_arn" {
  description = "KMS key in the DR region."
  type        = string
}

variable "enable_rtc" {
  description = "Enable S3 Replication Time Control (15-minute SLA, extra per-GB cost)."
  type        = bool
  default     = false
}

variable "noncurrent_days" {
  description = "Days to keep previous object versions."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Allow terraform destroy to empty the buckets (lab teardown)."
  type        = bool
  default     = true
}
