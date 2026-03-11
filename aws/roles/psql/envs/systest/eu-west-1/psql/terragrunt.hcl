# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/psql/terragrunt.hcl
#
# Deploys PSQL IAM Role to systest in eu-west-1 (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/psql.hcl"
  expose = true
}
