# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/github-oidc/terragrunt.hcl
#
# Deploys GitHub OIDC provider and IAM roles to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/github-oidc.hcl"
  expose = true
}
