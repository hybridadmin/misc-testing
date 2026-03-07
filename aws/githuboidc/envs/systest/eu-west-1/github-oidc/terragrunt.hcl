# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/github-oidc/terragrunt.hcl
#
# Deploys GitHub OIDC provider and IAM roles to systest in eu-west-1
# (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/github-oidc.hcl"
  expose = true
}
