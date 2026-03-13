locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
}

terraform {
  source = "${get_repo_root()}/01_bootstrap/modules/kms-keys"
}

inputs = {
  project         = "myorg"
  environment     = local.account_name
  organization_id = "o-abc123def45"
  admin_role_name = "CrossAccountAdminAccess"
  alias_name      = "AmiEncryption"

  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "kms-keys"
  }
}
