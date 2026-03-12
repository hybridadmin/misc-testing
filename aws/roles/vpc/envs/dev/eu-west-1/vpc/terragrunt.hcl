# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - dev / eu-west-1
#
# Deploys VPC into the dev account in eu-west-1.
# Cost-optimized: single NAT gateway, REJECT-only flow logs.
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
  # No additional overrides needed for dev -- env.hcl + envcommon provide all defaults.
  # Add per-region overrides here if deploying to multiple regions.
}
