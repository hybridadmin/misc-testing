# Backup Vault - us-west-2 (Oregon)
# Deploys: KMS key, Backup Vault, S3 bucket, Cross-account IAM role

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules//backup-vault"
}

inputs = {
  project            = local.env_vars.locals.project
  environment        = local.env_vars.locals.environment
  backup_account_id  = local.env_vars.locals.backup_account_id
  devops_account_id  = local.env_vars.locals.devops_account_id
  organization_id    = local.env_vars.locals.organization_id
  production_ou_path = local.env_vars.locals.production_ou_path

  tags = {
    project     = local.env_vars.locals.project
    environment = local.env_vars.locals.environment
    service     = "backups"
  }
}
