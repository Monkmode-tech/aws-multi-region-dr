###############################################################################
# Route 53 health-checked failover.
#
#   ledger.<domain>  A  PRIMARY   -> us-east-2 API custom domain (health checked)
#                    A  SECONDARY -> us-east-1 API custom domain (health checked)
#
# The primary health check hits the regional execute-api hostname directly
# (not the shared name, which would follow the failover and test the wrong
# region). /health does a real read against that region's table replica, so
# a broken database in the primary region also triggers failover.
#
# Detection time ~= request_interval x failure_threshold (10s x 3 = 30s),
# plus the alias record TTL for clients to pick up the change.
###############################################################################

data "aws_region" "metrics" {
  provider = aws.us_east_1
}

locals {
  checks = {
    primary = {
      host     = var.primary.execute_api_host
      interval = 10
      label    = "primary (${var.primary.region})"
    }
    secondary = {
      host     = var.secondary.execute_api_host
      interval = 30
      label    = "secondary (${var.secondary.region})"
    }
  }
}

resource "aws_route53_health_check" "this" {
  for_each = local.checks

  type              = "HTTPS_STR_MATCH"
  fqdn              = each.value.host
  port              = 443
  resource_path     = "/health"
  search_string     = "\"status\": \"ok\""
  request_interval  = each.value.interval
  failure_threshold = 3
  enable_sni        = true

  # Three checker regions (the minimum) keep health-check traffic - and the
  # Lambda/API Gateway requests it generates - low for a lab budget.
  regions = var.checker_regions

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_route53_record" "failover" {
  for_each = {
    primary   = var.primary
    secondary = var.secondary
  }

  zone_id         = var.zone_id
  name            = var.fqdn
  type            = "A"
  set_identifier  = each.key
  health_check_id = aws_route53_health_check.this[each.key].id

  failover_routing_policy {
    type = upper(each.key)
  }

  alias {
    name                   = each.value.domain_target
    zone_id                = each.value.domain_zone_id
    evaluate_target_health = false
  }
}

# Route 53 publishes health-check metrics only in us-east-1.
resource "aws_cloudwatch_metric_alarm" "health" {
  for_each = local.checks
  provider = aws.us_east_1

  alarm_name          = "${var.name}-${each.key}-unhealthy"
  alarm_description   = "Route 53 reports the ${each.value.label} region unhealthy - traffic is (or would be) failing over."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.this[each.key].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  lifecycle {
    precondition {
      condition     = data.aws_region.metrics.region == "us-east-1"
      error_message = "Route 53 health-check metrics only exist in us-east-1; pass a us-east-1 provider as aws.us_east_1."
    }
  }
}
