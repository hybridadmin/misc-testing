# -----------------------------------------------------------------------------
# locals.tf
#
# Computed values, naming conventions, and tag management.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  name_prefix = "${var.project}-${var.environment}-${var.service}"
  identifier  = var.identifier_override != "" ? var.identifier_override : local.name_prefix

  region = data.aws_region.current.name

  # ---------------------------------------------------------------------------
  # NAT Gateway logic
  # ---------------------------------------------------------------------------
  # Single NAT: all subnets route through one NAT in the first AZ.
  # Multi NAT:  one NAT per AZ for high availability.
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : 3) : 0

  # ---------------------------------------------------------------------------
  # Tags
  # ---------------------------------------------------------------------------
  default_tags = {
    Project     = var.project
    Environment = var.environment
    Service     = var.service
    ManagedBy   = "terraform"
  }

  tags = merge(local.default_tags, var.tags)

  # ---------------------------------------------------------------------------
  # Flow log KMS key (empty-string-to-null coercion)
  # ---------------------------------------------------------------------------
  flow_log_kms_key_id = var.flow_log_cloudwatch_kms_key_id != "" ? var.flow_log_cloudwatch_kms_key_id : null
  flow_log_s3_arn     = var.flow_log_s3_bucket_arn != "" ? var.flow_log_s3_bucket_arn : null
}
