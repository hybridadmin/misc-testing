# -----------------------------------------------------------------------------
# _envcommon/alb.hcl
#
# Shared Terragrunt configuration for the ALB component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/alb/
# or envs/<env>/<region>/<account_id>/alb/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/alb/modules/alb"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # Networking - these must be provided per-environment in env.hcl
  vpc_id     = local.env_vars.locals.vpc_id
  subnet_ids = local.env_vars.locals.subnet_ids
  internal   = try(local.env_vars.locals.internal, false)

  # TLS
  certificate_arn = local.env_vars.locals.certificate_arn
  ssl_policy      = try(local.env_vars.locals.ssl_policy, "ELBSecurityPolicy-TLS-1-2-Ext-2018-06")

  # Ports
  http_port  = try(local.env_vars.locals.http_port, 80)
  https_port = try(local.env_vars.locals.https_port, 443)

  # Access Logs
  enable_access_logs = try(local.env_vars.locals.enable_access_logs, true)
  access_logs_bucket = try(local.env_vars.locals.access_logs_bucket, "")
  access_logs_prefix = try(local.env_vars.locals.access_logs_prefix, "alb")

  # WAF
  enable_waf      = try(local.env_vars.locals.enable_waf, false)
  waf_rule_action = try(local.env_vars.locals.waf_rule_action, "count")

  # Logging
  log_retention_days = try(local.env_vars.locals.log_retention_days, 180)
}
