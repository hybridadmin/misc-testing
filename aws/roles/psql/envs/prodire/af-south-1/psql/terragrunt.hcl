# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/psql/terragrunt.hcl
#
# Deploys PSQL IAM Role to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/psql.hcl"
  expose = true
}
