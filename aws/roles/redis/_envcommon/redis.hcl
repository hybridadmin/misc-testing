# -----------------------------------------------------------------------------
# _envcommon/redis.hcl
#
# Shared Terragrunt configuration for the ElastiCache Valkey component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/redis/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/redis/modules/redis"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  vpc_id             = local.env_vars.locals.vpc_id
  vpc_cidr           = local.env_vars.locals.vpc_cidr
  private_subnet_ids = local.env_vars.locals.private_subnet_ids

  # Cluster settings - defaults can be overridden per-environment in env.hcl
  node_type          = try(local.env_vars.locals.node_type, "cache.t4g.micro")
  engine_version     = try(local.env_vars.locals.engine_version, "7.2")
  parameter_family   = try(local.env_vars.locals.parameter_family, "valkey7")
  num_shards         = try(local.env_vars.locals.num_shards, 1)
  replicas_per_shard = try(local.env_vars.locals.replicas_per_shard, 1)

  # Cost controls - override per-environment for savings
  snapshot_retention_limit = try(local.env_vars.locals.snapshot_retention_limit, 7)
  use_custom_kms_key      = try(local.env_vars.locals.use_custom_kms_key, true)
}
