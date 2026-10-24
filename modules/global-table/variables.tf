variable "name" {
  description = "Table name (identical in every region)."
  type        = string
}

variable "replica_region" {
  description = "Region of the second replica (the DR region)."
  type        = string
}

variable "primary_kms_key_arn" {
  description = "KMS key in the primary region."
  type        = string
}

variable "replica_kms_key_arn" {
  description = "KMS key in the replica region."
  type        = string
}

variable "deletion_protection" {
  description = "Block table deletion. Turn off only to tear the lab down."
  type        = bool
  default     = true
}
