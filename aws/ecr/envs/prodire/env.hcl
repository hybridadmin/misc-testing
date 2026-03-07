# -----------------------------------------------------------------------------
# envs/prodire/env.hcl
#
# Environment-level variables for the prodire (Production Ireland) environment.
#
# This environment deploys ECR governance Lambdas across multiple accounts
# in the specified OUs. Use the generate_account_dirs.sh script to scaffold
# per-account directories, or manually add account directories under each
# region.
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "ecr"
  environment = "prodire"
  account_id  = "000000000000"   # Override per-account in account.hcl

  log_retention_days = 30

  # ECR lifecycle policy settings
  enable_lifecycle_policy   = false   # Set to true to auto-attach lifecycle policies
  lifecycle_max_image_count = 10

  # Cross-account ECR access: accounts that can pull images
  ecr_pull_account_ids = [
    "111111111111",   # Production Account 1
    "222222222222",   # Production Account 2
    "333333333333",   # Development Account 1
    "444444444444",   # Development Account 2
    "555555555555",   # Services Account 1
    "666666666666",   # Services Account 2
    "777777777777",   # Services Account 3
    "888888888888",   # Services Account 4
  ]

  # Cross-account ECR access: accounts that can push images
  ecr_push_account_ids = [
    "111111111111",   # CI/CD Account (typically the central build account)
  ]

  # Target OUs and regions for multi-account deployment
  # Used by scripts/generate_account_dirs.sh
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa",   # Production Accounts OU
    "ou-xxxx-bbbbbbbb",   # Development Accounts OU
    "ou-xxxx-cccccccc",   # Services Accounts OU
  ]

  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
