# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "redis"
  environment = "systest"
  account_id  = "000000000000"

  # Networking - update these with values from your VPC stack outputs
  vpc_id   = "vpc-0123456789abcdef0"
  vpc_cidr = "10.0.0.0/16"

  private_subnet_ids = [
    "subnet-0aaaaaaaaaaaaaaa0",
    "subnet-0bbbbbbbbbbbbbbbb0",
  ]

  # Cluster settings (override defaults from _envcommon/redis.hcl)
  node_type      = "cache.t4g.micro"
  engine_version = "7.2"
  num_shards     = 1
  replicas_per_shard = 0 # Single node — no replica (minimum cost)

  # Cost-saving overrides for systest
  snapshot_retention_limit = 1     # Keep 1 day of snapshots
  use_custom_kms_key      = false  # Use free AWS-managed key instead of custom KMS ($1/mo)
}
