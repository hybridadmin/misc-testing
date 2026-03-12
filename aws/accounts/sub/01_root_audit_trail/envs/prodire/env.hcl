# -----------------------------------------------------------------------------
# envs/prodire/env.hcl
#
# Environment-level variables for the prodire (Production Ireland) environment.
#
# In multi-account mode, each account in the target OUs gets its own leaf
# directory. Use the generate_account_dirs.sh helper or manually add
# account directories under each region.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "root-audit-trail"
  environment = "prodire"
  account_id  = "000000000000"   # Override per-account in account.hcl

  # Email addresses to receive root sign-in notifications
  email_addresses = [
    "security-alerts@example.com",
  ]

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
