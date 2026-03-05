# -----------------------------------------------------------------------------
# envs/prodire/env.hcl
#
# Environment-level variables for the prodire (Production Ireland) environment.
#
# In the original Ansible deployment, this targeted:
#   - Production Accounts OU  (ou-xxxx-aaaaaaaa)
#   - Development Accounts OU (ou-xxxx-bbbbbbbb)
#   - Services Accounts OU    (ou-xxxx-cccccccc)
#
# With the Terragrunt approach, each account in those OUs gets its own
# leaf directory. Use the generate_accounts.sh helper or manually add
# account directories under each region.
# -----------------------------------------------------------------------------

locals {
  project            = "devops"
  service            = "logsalarm"
  environment        = "prodire"
  account_id         = "000000000000"   # Override per-account in account.hcl
  log_retention_days = 30

  # For reference / documentation - the OUs this should cover
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
