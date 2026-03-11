# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/valkey/terragrunt.hcl
#
# Deploys Valkey IAM Roles to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/valkey.hcl"
  expose = true
}
