output "source_bucket" {
  description = "Source bucket name (primary region)."
  value       = aws_s3_bucket.source.id
}

output "replica_bucket" {
  description = "Replica bucket name (DR region)."
  value       = aws_s3_bucket.replica.id
}
