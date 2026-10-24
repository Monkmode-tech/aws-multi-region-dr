output "key_arn" {
  description = "Regional KMS key ARN."
  value       = aws_kms_key.this.arn
}
