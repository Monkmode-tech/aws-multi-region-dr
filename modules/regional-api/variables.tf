variable "name" {
  description = "Name prefix."
  type        = string
}

variable "fqdn" {
  description = "Public API hostname shared by both regions (e.g. api.example.com)."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone for certificate validation."
  type        = string
}

variable "table_name" {
  description = "DynamoDB global table name (a replica exists in every region)."
  type        = string
}

variable "kms_key_arn" {
  description = "This region's KMS key."
  type        = string
}

variable "handler_source_file" {
  description = "Path to the Lambda handler.py."
  type        = string
}

variable "reserved_concurrency" {
  description = "Reserved (maximum) concurrent executions of the API Lambda; -1 = unreserved. New accounts limited to 10 executions must leave this at -1."
  type        = number
  default     = -1
}

variable "throttle_rate" {
  description = "Steady-state requests per second allowed by the API stage."
  type        = number
  default     = 20
}

variable "throttle_burst" {
  description = "Burst requests allowed by the API stage."
  type        = number
  default     = 40
}

variable "alert_email" {
  description = "Email for regional alarms. Empty = no subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Log retention."
  type        = number
  default     = 30
}
