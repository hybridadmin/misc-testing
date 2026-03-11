# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/eksservice/terragrunt.hcl
#
# Deploys EKS Service IAM Role to systest in eu-west-1 (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/eksservice.hcl"
  expose = true
}
