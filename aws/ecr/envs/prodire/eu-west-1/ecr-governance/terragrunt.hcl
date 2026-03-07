# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - prodire / eu-west-1
#
# Deploys ECR governance Lambdas into the default prodire account in eu-west-1.
# For multi-account deployments, use scripts/generate_account_dirs.sh to create
# per-account directories under this region.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/ecr-governance.hcl"
  expose = true
}

locals {
  account_vars = try(read_terragrunt_config(find_in_parent_folders("account.hcl")), null)
}

inputs = {
  # Override inputs per account/region here if needed
}
