# -----------------------------------------------------------------------------
# _envcommon/root_audit_trail.hcl
#
# Shared Terragrunt configuration for the root_audit_trail component.
# Included by each leaf-level terragrunt.hcl in
#   envs/<env>/<region>/root_audit_trail/
#   envs/<env>/<region>/<account_id>/root_audit_trail/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/01_root_audit_trail/master/modules/root_audit_trail"
}

locals {
  # Parse environment variables
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  email_addresses = local.env_vars.locals.email_addresses
}
