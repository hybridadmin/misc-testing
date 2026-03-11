# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/eksservice/terragrunt.hcl
#
# Deploys EKS Service IAM Role to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/eksservice.hcl"
  expose = true
}
