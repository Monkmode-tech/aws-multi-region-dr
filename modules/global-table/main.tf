###############################################################################
# DynamoDB global table (version 2019.11.21) - active/active replication.
#
# The table lives in the primary region with a replica in the DR region. Both
# replicas accept writes; DynamoDB replicates asynchronously (typically under
# a second), which is what sets this design's RPO. Each replica is encrypted
# with a key in its own region and has point-in-time recovery, because
# replication copies mistakes too (see docs/dr-strategy.md, "replication is
# not backup").
###############################################################################

resource "aws_dynamodb_table" "this" {
  name                        = var.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "id"
  deletion_protection_enabled = var.deletion_protection

  # Streams are how global tables replicate; NEW_AND_OLD_IMAGES is required.
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.primary_kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  replica {
    region_name            = var.replica_region
    kms_key_arn            = var.replica_kms_key_arn
    point_in_time_recovery = true
    propagate_tags         = true
  }

  tags = {
    Backup = "true"
  }
}
