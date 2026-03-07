# -----------------------------------------------------------------------------
# _envcommon/ecr-governance.hcl
#
# Shared Terragrunt configuration for the ecr-governance component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/ecr-governance/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/ecr/modules/ecr-governance"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  add_permissions_source_path = "${get_repo_root()}/aws/ecr/src/add_permissions.py"
  attach_policy_source_path   = "${get_repo_root()}/aws/ecr/src/attach_policy.py"

  log_retention_days        = local.env_vars.locals.log_retention_days
  enable_lifecycle_policy   = local.env_vars.locals.enable_lifecycle_policy
  lifecycle_max_image_count = local.env_vars.locals.lifecycle_max_image_count
  ecr_pull_account_ids      = local.env_vars.locals.ecr_pull_account_ids
  ecr_push_account_ids      = local.env_vars.locals.ecr_push_account_ids
}
