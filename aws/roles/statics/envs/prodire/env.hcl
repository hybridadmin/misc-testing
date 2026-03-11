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
  service     = "statics"
  environment = "prodire"
  account_id  = "000000000000"   # Override per-account in account.hcl

  # SNS-to-Email Lambda function ARN (set to "" to skip SNS subscriptions)
  sns_to_email_lambda_arn = ""

  # Logs bucket lifecycle
  logs_expiration_days = 180

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
