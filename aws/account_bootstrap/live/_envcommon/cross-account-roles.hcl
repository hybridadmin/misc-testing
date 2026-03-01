# -----------------------------------------------------------------------------
# Common Terragrunt configuration for the cross-account-roles module.
#
# This file is included by each account's cross-account-roles/terragrunt.hcl
# via: include "envcommon" { ... expose = true }
#
# It centralises the module source and shared input variables so that
# account-level configs only need to provide overrides.
# -----------------------------------------------------------------------------

locals {
  # Resolve the account-level variables
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
}

terraform {
  source = "${get_repo_root()}/modules/cross-account-roles"
}

inputs = {
  # -------------------------------------------------------------------------
  # IMPORTANT: Replace with your actual identity/management account ID
  # -------------------------------------------------------------------------
  trusted_account_id = "283837321132"

  require_mfa          = true
  admin_role_name      = "CrossAccountAdminAccess"
  read_only_role_name  = "CrossAccountReadAccess"
  role_path            = "/"
  max_session_duration = 3600

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "cross-account-roles"
  }
}
