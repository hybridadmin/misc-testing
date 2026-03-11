include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//master-account-roles"
}

inputs = {
  backup_services_account_id  = local.common_vars.locals.backup_services_account_id
  route53_trusted_account_ids = local.common_vars.locals.route53_trusted_account_ids
  hosted_zone_ids             = local.common_vars.locals.hosted_zone_ids
}
