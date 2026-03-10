###############################################################################
# Locals
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Naming convention
  name_prefix = "${var.project}-${var.environment}-${var.service}"
  identifier  = var.identifier_override != "" ? var.identifier_override : local.name_prefix

  # Derive parameter group family from engine version if not explicitly set
  major_version = split(".", var.engine_version)[0]
  family        = var.family != "" ? var.family : "postgres${local.major_version}"

  # KMS key handling -- use provided key or fall back to default
  storage_kms_key_id = var.kms_key_id != "" ? var.kms_key_id : null
  secret_kms_key_id  = var.master_user_secret_kms_key_id != "" ? var.master_user_secret_kms_key_id : null

  # Final snapshot name
  final_snapshot_identifier = "${var.final_snapshot_identifier_prefix}-${local.identifier}-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  # Monitoring -- only create a role if enhanced monitoring is enabled and no external role is provided
  create_monitoring_role = var.monitoring_interval > 0 && var.monitoring_role_arn == ""
  monitoring_role_arn    = local.create_monitoring_role ? aws_iam_role.enhanced_monitoring[0].arn : var.monitoring_role_arn

  # Default tags applied to all resources
  default_tags = {
    Project     = var.project
    Environment = var.environment
    Service     = var.service
    ManagedBy   = "terraform"
  }

  tags = merge(local.default_tags, var.tags)

  ###########################################################################
  # Best-practice PG parameters (merged with user-supplied overrides)
  ###########################################################################
  default_parameters = [
    # Logging
    {
      name         = "log_connections"
      value        = "1"
      apply_method = "immediate"
    },
    {
      name         = "log_disconnections"
      value        = "1"
      apply_method = "immediate"
    },
    {
      name         = "log_checkpoints"
      value        = "1"
      apply_method = "immediate"
    },
    {
      name         = "log_lock_waits"
      value        = "1"
      apply_method = "immediate"
    },
    {
      name         = "log_min_duration_statement"
      value        = "1000"
      apply_method = "immediate"
    },
    {
      name         = "log_statement"
      value        = "ddl"
      apply_method = "immediate"
    },
    # Shared preload libraries (pg_stat_statements is critical for perf analysis)
    {
      name         = "shared_preload_libraries"
      value        = "pg_stat_statements"
      apply_method = "pending-reboot"
    },
    {
      name         = "pg_stat_statements.track"
      value        = "all"
      apply_method = "immediate"
    },
    # Connection handling
    {
      name         = "idle_in_transaction_session_timeout"
      value        = "300000"
      apply_method = "immediate"
    },
    # SSL enforcement
    {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "immediate"
    },
  ]

  # Merge default params with user-supplied ones; user values take precedence
  user_param_names   = [for p in var.parameter_group_parameters : p.name]
  merged_parameters = concat(
    [for p in local.default_parameters : p if !contains(local.user_param_names, p.name)],
    var.parameter_group_parameters,
  )
}
