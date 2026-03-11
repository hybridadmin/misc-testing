# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "redisefs"
  environment = "systest"
  account_id  = "000000000000"

  # Networking - update these with values from your VPC stack outputs
  vpc_id   = "vpc-0123456789abcdef0"
  vpc_cidr = "10.0.0.0/16"

  private_subnet_ids = [
    "subnet-0aaaaaaaaaaaaaaa0",
    "subnet-0bbbbbbbbbbbbbbbb0",
  ]
}
