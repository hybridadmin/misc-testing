# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/redis/terragrunt.hcl
#
# Deploys ElastiCache Redis cluster to prodire in eu-west-1.
#
# For multi-account deployment across OUs, use generate_account_dirs.sh to
# create a directory per target account. Each account directory will contain
# its own account.hcl and leaf terragrunt.hcl.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/redis.hcl"
  expose = true
}

# Override account_id, networking, or cluster config if deploying to a specific account
# inputs = {
#   vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
#   vpc_cidr           = "10.1.0.0/16"
#   private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
#   node_type          = "cache.r7g.xlarge"
#   num_shards         = 3
# }
