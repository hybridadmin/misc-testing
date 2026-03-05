# Member Account - us-west-2 (Oregon / Backup Region)
# Backup region: KMS + vault only, NO backup plan (this is the copy destination),
# NO event forwarding (events here are not forwarded)

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../../modules//member-account"
}

inputs = {
  project            = local.env_vars.locals.project
  environment        = local.env_vars.locals.environment
  devops_account_id  = local.env_vars.locals.devops_account_id
  backup_account_id  = local.env_vars.locals.backup_account_id
  backup_region      = local.env_vars.locals.backup_region
  devops_event_bus_arn = local.env_vars.locals.devops_event_bus_arn

  # Oregon is the copy target - no backup plan or event forwarding
  enable_backup_plan                  = false
  enable_event_forwarding_role        = false
  enable_cross_account_role           = false

  enable_backup_copy_event_forwarding = false
  enable_ec2_event_forwarding         = false
  enable_ecr_event_forwarding         = false

  is_cape_town = false

  tags = {
    project     = local.env_vars.locals.project
    environment = local.env_vars.locals.environment
    service     = "backups"
  }
}
