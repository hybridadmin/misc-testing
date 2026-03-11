# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/redis/terragrunt.hcl
#
# Deploys ElastiCache Redis cluster to systest in eu-west-1 (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/redis.hcl"
  expose = true
}
