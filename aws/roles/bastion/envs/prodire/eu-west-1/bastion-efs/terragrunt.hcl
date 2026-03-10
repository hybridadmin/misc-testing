# -----------------------------------------------------------------------------
# Deploys bastion-efs into prodire / eu-west-1
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/bastion-efs.hcl"
  expose = true
}
