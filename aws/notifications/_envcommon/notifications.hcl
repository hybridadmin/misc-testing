# -----------------------------------------------------------------------------
# _envcommon/notifications.hcl
#
# Shared Terragrunt configuration for the notifications component.
# Included by each leaf-level terragrunt.hcl in
#   envs/<env>/<region>/<account_id>/notifications/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/notifications/modules/notifications"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  lambda_source_path = "${get_repo_root()}/aws/notifications/src/lambda_function.py"
  log_retention_days = local.env_vars.locals.log_retention_days
  slack_webhook_url  = local.env_vars.locals.slack_webhook_url
  slack_channel      = local.env_vars.locals.slack_channel
}
