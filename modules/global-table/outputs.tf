output "name" {
  description = "Table name."
  value       = aws_dynamodb_table.this.name
}

output "arn" {
  description = "Primary-region table ARN."
  value       = aws_dynamodb_table.this.arn
}
