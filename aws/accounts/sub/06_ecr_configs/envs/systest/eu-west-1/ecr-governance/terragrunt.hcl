# -----------------------------------------------------------------------------
# Leaf terragrunt.hcl - systest / eu-west-1
#
# Deploys ECR governance Lambdas into the systest account in eu-west-1.
# Single-account environment for testing.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/ecr-governance.hcl"
  expose = true
}

inputs = {
  # Override inputs for systest here if needed
}
