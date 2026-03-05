# Member Account - eu-west-1 (Ireland)
# Primary region: creates EventBridge forwarding role, cross-account role, backup plan, and all event rules

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

  # eu-west-1 is the primary region
  enable_backup_plan                  = true
  enable_event_forwarding_role        = true
  enable_cross_account_role           = true

  # Event forwarding: don't forward backup copy events from primary (would forward to self)
  # and don't forward from Oregon. EC2 events DO forward from primary for member accounts.
  # Note: For the devops account itself in Ireland, these should be disabled
  # (handled by deploying this module only to non-devops member accounts)
  enable_backup_copy_event_forwarding = true
  enable_ec2_event_forwarding         = true
  enable_ecr_event_forwarding         = true

  is_cape_town = false

  tags = {
    project     = local.env_vars.locals.project
    environment = local.env_vars.locals.environment
    service     = "backups"
  }
}
