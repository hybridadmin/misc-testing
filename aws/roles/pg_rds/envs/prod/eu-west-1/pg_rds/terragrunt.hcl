# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - prod / eu-west-1
#
# Deploys PostgreSQL RDS into the production account in eu-west-1.
# Full HA, encryption, monitoring, and strict protection settings.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/pg_rds.hcl"
  expose = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # Production-specific overrides
  max_allocated_storage = local.env_vars.locals.max_allocated_storage
  multi_az              = local.env_vars.locals.multi_az

  # Backup -- maximum retention and protection
  backup_retention_period = local.env_vars.locals.backup_retention_period
  skip_final_snapshot     = local.env_vars.locals.skip_final_snapshot
  deletion_protection     = local.env_vars.locals.deletion_protection
  apply_immediately       = local.env_vars.locals.apply_immediately

  # Auto upgrades disabled -- controlled via blue/green deployments
  auto_minor_version_upgrade = local.env_vars.locals.auto_minor_version_upgrade

  # Monitoring -- aggressive
  monitoring_interval                   = local.env_vars.locals.monitoring_interval
  performance_insights_enabled          = local.env_vars.locals.performance_insights_enabled
  performance_insights_retention_period = local.env_vars.locals.performance_insights_retention_period
  create_cloudwatch_alarms              = local.env_vars.locals.create_cloudwatch_alarms

  # Read replicas for production read scaling
  read_replicas = local.env_vars.locals.read_replicas

  # Database
  db_name = "appdb"

  # Blue/green deployments for safer upgrades
  blue_green_update_enabled = true
}
