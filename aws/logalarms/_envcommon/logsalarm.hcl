# -----------------------------------------------------------------------------
# _envcommon/logsalarm.hcl
#
# Shared Terragrunt configuration for the logsalarm component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/logsalarm/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/logalarms/modules/logsalarm"
}

locals {
  # Parse environment and region from the directory path
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  lambda_source_path = "${get_repo_root()}/aws/logalarms/src/lambda_function.py"
  log_retention_days = local.env_vars.locals.log_retention_days
}
