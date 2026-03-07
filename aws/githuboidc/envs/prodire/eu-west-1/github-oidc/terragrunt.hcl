# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/github-oidc/terragrunt.hcl
#
# Deploys GitHub OIDC provider and IAM roles to prodire in eu-west-1.
#
# For multi-account deployment across OUs, create a directory per target
# account using generate_account_dirs.sh, or manually add account
# directories under each region.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/github-oidc.hcl"
  expose = true
}
