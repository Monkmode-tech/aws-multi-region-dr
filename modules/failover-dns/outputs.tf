output "health_check_ids" {
  description = "Route 53 health check IDs by role (primary, secondary)."
  value       = { for k, hc in aws_route53_health_check.this : k => hc.id }
}
