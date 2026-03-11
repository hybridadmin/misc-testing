# -----------------------------------------------------------------------------
# _envcommon/statics.hcl
#
# Shared Terragrunt configuration for the statics component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/statics/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/statics/modules/statics"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  sns_to_email_lambda_arn = try(local.env_vars.locals.sns_to_email_lambda_arn, "")
  logs_expiration_days    = try(local.env_vars.locals.logs_expiration_days, 180)
}
