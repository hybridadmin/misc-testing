# -----------------------------------------------------------------------------
# _envcommon/redisefs.hcl
#
# Shared Terragrunt configuration for the Redis EFS component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/redisefs/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/redisefs/modules/redisefs"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  vpc_id             = local.env_vars.locals.vpc_id
  vpc_cidr           = local.env_vars.locals.vpc_cidr
  private_subnet_ids = local.env_vars.locals.private_subnet_ids
}
