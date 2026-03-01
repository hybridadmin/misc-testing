# -----------------------------------------------------------------------------
# Common Terragrunt configuration for the backup-vault module.
#
# This file is included by the backup account's backup-vault/terragrunt.hcl
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
  aws_region   = local.account_vars.locals.aws_region
}

terraform {
  source = "${get_repo_root()}/modules/backup-vault"
}

inputs = {
  # -------------------------------------------------------------------------
  # IMPORTANT: Replace placeholder values with your actual environment config
  # -------------------------------------------------------------------------
  name            = "hbdorg-production-backups"
  organization_id = "o-pfayzcebx5"

  backup_source_account_ids = ["520453265019"] # Production account(s) that send backups

  sns_topic_arn       = "arn:aws:sns:${local.aws_region}:${local.account_id}:devops-events-general"
  notification_events = ["COPY_JOB_FAILED"]

  admin_role_name         = "CrossAccountAdminAccess"
  cross_account_role_name = "HBDORG-PRODUCTION-BACKUP-CrossAccountBackupRole"

  # Production accounts OU path for S3 bucket read access
  bucket_read_org_paths = ["o-pfayzcebx5/r-zkdv/ou-zkdv-a0k0yvv1"]

  backup_retention_days       = 180
  kms_deletion_window_in_days = 30
  enable_key_rotation         = true

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "backup-vault"
  }
}
