include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//audit-resources"
}

inputs = {
  organization_id             = local.common_vars.locals.organization_id
  admin_role_name             = "CrossAccountAdminAccess"
  cloudtrail_bucket_name      = local.common_vars.locals.cloudtrail_bucket_name
  config_bucket_name          = local.common_vars.locals.config_bucket_name
  conformance_bucket_name     = local.common_vars.locals.conformance_bucket_name
  cloudtrail_write_account_id = local.common_vars.locals.cloudtrail_write_account_id
  devops_account_id           = local.common_vars.locals.devops_account_id
}
