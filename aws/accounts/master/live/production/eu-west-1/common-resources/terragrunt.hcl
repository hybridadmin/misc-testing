include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//common-resources"
}

inputs = {
  critical_notifications_email = local.common_vars.locals.critical_notifications_email
  general_notifications_email  = local.common_vars.locals.general_notifications_email
}
