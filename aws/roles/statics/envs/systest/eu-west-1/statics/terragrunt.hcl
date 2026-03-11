# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/statics/terragrunt.hcl
#
# Deploys Statics resources to systest in eu-west-1 (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/statics.hcl"
  expose = true
}
