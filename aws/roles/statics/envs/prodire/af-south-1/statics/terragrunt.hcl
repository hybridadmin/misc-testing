# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/statics/terragrunt.hcl
#
# Deploys Statics resources to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/statics.hcl"
  expose = true
}
