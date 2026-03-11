include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//config-recorder"
}

inputs = {
  config_s3_bucket_name = local.common_vars.locals.config_bucket_name
  config_kms_key_arn    = local.common_vars.locals.config_kms_key_arn
}
