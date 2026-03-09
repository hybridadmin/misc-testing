# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "ecr"
  environment = "systest"
  account_id  = "000000000000"

  log_retention_days = 30

  # ECR lifecycle policy settings
  enable_lifecycle_policy   = true   # Enable for testing
  lifecycle_max_image_count = 10

  # Cross-account ECR access (minimal for testing)
  ecr_pull_account_ids = [
    "000000000000",   # Self (systest account)
  ]

  ecr_push_account_ids = [
    "000000000000",   # Self (systest account)
  ]
}
