variable "name" {
  description = "Name prefix."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone ID."
  type        = string
}

variable "fqdn" {
  description = "Shared API hostname that fails over."
  type        = string
}

variable "primary" {
  description = "Primary regional API (outputs of modules/regional-api)."
  type = object({
    region           = string
    execute_api_host = string
    domain_target    = string
    domain_zone_id   = string
  })
}

variable "secondary" {
  description = "DR regional API (outputs of modules/regional-api)."
  type = object({
    region           = string
    execute_api_host = string
    domain_target    = string
    domain_zone_id   = string
  })
}

variable "checker_regions" {
  description = "Route 53 health-checker regions (minimum three)."
  type        = list(string)
  default     = ["us-east-1", "us-west-2", "eu-west-1"]

  validation {
    condition     = length(var.checker_regions) >= 3
    error_message = "Route 53 requires at least three health-checker regions."
  }
}

variable "alarm_topic_arn" {
  description = "SNS topic in us-east-1 for health-check alarms."
  type        = string
}
