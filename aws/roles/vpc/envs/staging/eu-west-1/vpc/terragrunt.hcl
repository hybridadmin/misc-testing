# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - staging / eu-west-1
#
# Deploys VPC into the staging account in eu-west-1.
# Mirrors production architecture with single NAT for cost optimization.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/vpc.hcl"
  expose = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # No additional overrides needed for staging -- env.hcl + envcommon provide all defaults.
  # Add per-region overrides here if deploying to multiple regions.
}
