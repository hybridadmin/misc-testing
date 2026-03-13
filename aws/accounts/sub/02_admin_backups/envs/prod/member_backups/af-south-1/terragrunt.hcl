# Member Backups - af-south-1 (Cape Town)
# Secondary region: backup plan + limited event forwarding (no org-level permissions)

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../../modules//member_backups"
}

inputs = {
  project            = local.env_vars.locals.project
  environment        = local.env_vars.locals.environment
  devops_account_id  = local.env_vars.locals.devops_account_id
  backup_account_id  = local.env_vars.locals.backup_account_id
  backup_region      = local.env_vars.locals.backup_region
  devops_event_bus_arn = local.env_vars.locals.devops_event_bus_arn

  enable_backup_plan                  = true
  enable_event_forwarding_role        = false  # Role created in eu-west-1 only
  enable_cross_account_role           = false  # Role created in eu-west-1 only

  enable_backup_copy_event_forwarding = true
  enable_ec2_event_forwarding         = true
  enable_ecr_event_forwarding         = true

  # Cape Town has organizational permission limitations
  is_cape_town = true

  tags = {
    project     = local.env_vars.locals.project
    environment = local.env_vars.locals.environment
    service     = "backups"
  }
}
