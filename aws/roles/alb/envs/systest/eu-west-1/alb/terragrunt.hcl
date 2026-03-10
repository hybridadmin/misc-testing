# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - systest / eu-west-1
#
# Deploys ALB into the systest account in eu-west-1.
# Single-account environment -- no account.hcl needed.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/alb.hcl"
  expose = true
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # No additional overrides needed for systest -- env.hcl + envcommon provide all defaults.
  # Add per-region overrides here if needed.
}
