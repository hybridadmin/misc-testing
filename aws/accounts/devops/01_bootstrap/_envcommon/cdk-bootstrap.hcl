locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
}

terraform {
  source = "${get_repo_root()}/01_bootstrap/modules/cdk-bootstrap"
}

inputs = {
  qualifier = "hnb659fds"

  trusted_accounts = [
    "000000000000", # TODO: Replace with your DevOps account ID
  ]

  trusted_accounts_for_lookup = []

  # Use restricted execution policy instead of AdministratorAccess
  # Reference the CFN execution policy created by the cross-account-roles module
  cloudformation_execution_policies = [
    "arn:aws:iam::${local.account_id}:policy/ORGPolicyForCfnExecution",
  ]

  file_assets_bucket_name       = ""  # Auto-generated
  file_assets_bucket_kms_key_id = ""  # Create new key
  container_assets_repository_name = "" # Auto-generated

  enable_public_access_block = true
  enable_ecr_image_scanning  = true
  enable_bucket_versioning   = true
  enable_kms_key_rotation    = true
  kms_key_deletion_window    = 30
  bootstrap_version          = "21"

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "cdk-bootstrap"
  }
}
