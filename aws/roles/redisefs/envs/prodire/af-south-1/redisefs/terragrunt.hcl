# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/redisefs/terragrunt.hcl
#
# Deploys Redis EFS to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/redisefs.hcl"
  expose = true
}

# Override account_id or networking if deploying to a specific account
# inputs = {
#   vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
#   vpc_cidr           = "10.2.0.0/16"
#   private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
# }
