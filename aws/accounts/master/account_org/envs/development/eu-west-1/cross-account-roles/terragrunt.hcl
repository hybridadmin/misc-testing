include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${dirname(find_in_parent_folders())}/_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//cross-account-roles"
}

inputs = {
  identity_account_id = local.common_vars.locals.identity_account_id
}
