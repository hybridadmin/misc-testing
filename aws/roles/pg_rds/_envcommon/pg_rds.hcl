# -----------------------------------------------------------------------------
# _envcommon/pg_rds.hcl
#
# Shared Terragrunt configuration for the pg_rds component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/pg_rds/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/pg_rds/modules/pg_rds"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # Networking -- these must be overridden per environment in env.hcl
  vpc_id     = local.env_vars.locals.vpc_id
  subnet_ids = local.env_vars.locals.subnet_ids

  # Engine
  engine_version = local.env_vars.locals.engine_version

  # Instance
  instance_class    = local.env_vars.locals.instance_class
  allocated_storage = local.env_vars.locals.allocated_storage

  # Access
  allowed_cidr_blocks        = try(local.env_vars.locals.allowed_cidr_blocks, [])
  allowed_security_group_ids = try(local.env_vars.locals.allowed_security_group_ids, [])

  # Alarms
  alarm_sns_topic_arns = try(local.env_vars.locals.alarm_sns_topic_arns, [])
}
