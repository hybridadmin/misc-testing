# -----------------------------------------------------------------------------
# envs/prodire/env.hcl
#
# Environment-level variables for the prodire (Production Ireland) environment.
#
# Multi-account deployment: each account in the target OUs gets its own
# leaf directory. Use scripts/generate_account_dirs.sh to scaffold the
# directory structure for all accounts automatically.
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "redis"
  environment = "prodire"
  account_id  = "000000000000"   # Override per-account in account.hcl

  # Networking defaults - override per-account in leaf terragrunt.hcl inputs
  # or use data sources to look up dynamically
  vpc_id   = "vpc-0123456789abcdef0"
  vpc_cidr = "10.0.0.0/16"

  private_subnet_ids = [
    "subnet-0aaaaaaaaaaaaaaa0",
    "subnet-0bbbbbbbbbbbbbbbb0",
  ]

  # Cluster settings (override defaults from _envcommon/redis.hcl)
  node_type          = "cache.r7g.large"
  engine_version     = "7.2"
  num_shards         = 2
  replicas_per_shard = 1

  # Target OUs to deploy across - used by generate_account_dirs.sh
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa", # Production Accounts OU
    "ou-xxxx-bbbbbbbb", # Development Accounts OU
    "ou-xxxx-cccccccc", # Services Accounts OU
  ]

  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
