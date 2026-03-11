# -----------------------------------------------------------------------------
# Common Terragrunt configuration for the kms-keys module.
#
# This file is included by each account's kms-keys/terragrunt.hcl
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
  source = "${get_repo_root()}/modules/kms-keys"
}

inputs = {
  # -------------------------------------------------------------------------
  # IMPORTANT: Replace with your actual AWS Organizations ID
  # -------------------------------------------------------------------------
  organization_id = "o-pfayzcebx5"

  alias_name              = "ami-encryption"
  key_description         = "AMI Encryption Key for Shared AMIs"
  admin_role_name         = "CrossAccountAdminAccess"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "kms-keys"
  }
}
