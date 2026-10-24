output "region" {
  description = "Region of this stack."
  value       = local.region
}

output "function_name" {
  description = "API Lambda name (the game day throttles it to simulate an outage)."
  value       = aws_lambda_function.api.function_name
}

output "execute_api_host" {
  description = "Region-specific API hostname (used by the Route 53 health check)."
  value       = replace(aws_apigatewayv2_api.this.api_endpoint, "https://", "")
}

output "domain_target" {
  description = "Regional target of the custom domain (alias target for Route 53)."
  value       = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].target_domain_name
}

output "domain_zone_id" {
  description = "Hosted zone ID of the regional custom-domain target."
  value       = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].hosted_zone_id
}

output "alerts_topic_arn" {
  description = "Regional SNS alerts topic."
  value       = aws_sns_topic.alerts.arn
}
