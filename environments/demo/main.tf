###############################################################################
# Multi-region warm standby (pilot-light compute cost, hot data):
#
#   ledger.<domain> --Route 53 failover--> us-east-2 (primary) | us-east-1 (DR)
#   each region: HTTP API -> Lambda -> local DynamoDB global-table replica
#   documents: S3 cross-region replication; backups: AWS Backup with DR copy
#
# Serverless in both regions means the standby costs almost nothing while
# idle yet is already "scaled up" - see docs/adr/0001.
###############################################################################

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

locals {
  fqdn       = "${var.api_subdomain}.${var.domain_name}"
  table_name = "${var.project}-items"
  handler    = "${path.module}/../../app/handler.py"
}

#------------------------------------------------------------------------------
# Keys (KMS keys are regional - one per region)
#------------------------------------------------------------------------------
module "kms_primary" {
  source = "../../modules/kms"

  name = var.project
}

module "kms_dr" {
  source = "../../modules/kms"
  providers = {
    aws = aws.dr
  }

  name = var.project
}

#------------------------------------------------------------------------------
# Data: DynamoDB global table (replica in each region)
#------------------------------------------------------------------------------
module "table" {
  source = "../../modules/global-table"

  name                = local.table_name
  replica_region      = var.dr_region
  primary_kms_key_arn = module.kms_primary.key_arn
  replica_kms_key_arn = module.kms_dr.key_arn
  deletion_protection = var.deletion_protection
}

#------------------------------------------------------------------------------
# Compute: identical API stack in each region
#------------------------------------------------------------------------------
module "api_primary" {
  source = "../../modules/regional-api"

  name                = var.project
  fqdn                = local.fqdn
  zone_id             = data.aws_route53_zone.this.zone_id
  table_name          = module.table.name
  kms_key_arn         = module.kms_primary.key_arn
  handler_source_file = local.handler
  alert_email         = var.alert_email

  reserved_concurrency = var.lambda_reserved_concurrency
}

module "api_dr" {
  source = "../../modules/regional-api"
  providers = {
    aws = aws.dr
  }

  name                = var.project
  fqdn                = local.fqdn
  zone_id             = data.aws_route53_zone.this.zone_id
  table_name          = module.table.name
  kms_key_arn         = module.kms_dr.key_arn
  handler_source_file = local.handler
  alert_email         = var.alert_email

  reserved_concurrency = var.lambda_reserved_concurrency
}

#------------------------------------------------------------------------------
# Traffic: Route 53 health-checked failover
#------------------------------------------------------------------------------
module "dns" {
  source = "../../modules/failover-dns"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.dr
  }

  name            = var.project
  zone_id         = data.aws_route53_zone.this.zone_id
  fqdn            = local.fqdn
  alarm_topic_arn = module.api_dr.alerts_topic_arn

  primary = {
    region           = module.api_primary.region
    execute_api_host = module.api_primary.execute_api_host
    domain_target    = module.api_primary.domain_target
    domain_zone_id   = module.api_primary.domain_zone_id
  }

  secondary = {
    region           = module.api_dr.region
    execute_api_host = module.api_dr.execute_api_host
    domain_target    = module.api_dr.domain_target
    domain_zone_id   = module.api_dr.domain_zone_id
  }
}

#------------------------------------------------------------------------------
# Objects: S3 cross-region replication
#------------------------------------------------------------------------------
module "documents" {
  source = "../../modules/replicated-bucket"
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  name                = "${var.project}-docs"
  source_kms_key_arn  = module.kms_primary.key_arn
  replica_kms_key_arn = module.kms_dr.key_arn
  enable_rtc          = var.enable_s3_rtc
}

#------------------------------------------------------------------------------
# Backups: daily, copied cross-region, DR vault locked
#------------------------------------------------------------------------------
module "backup" {
  source = "../../modules/backup"
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  name                = var.project
  primary_kms_key_arn = module.kms_primary.key_arn
  dr_kms_key_arn      = module.kms_dr.key_arn
  alerts_topic_arn    = module.api_primary.alerts_topic_arn
}
