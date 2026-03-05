locals {
  project            = "devops"
  service            = "notifications"
  environment        = "prod"
  account_id         = "000000000000" # Override per-account in account.hcl

  log_retention_days = 30

  # Slack configuration
  slack_channel     = "owner-maintenance-notifications"
  slack_webhook_url = "tbc"

  # Target OUs and regions for generate_account_dirs.sh
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
