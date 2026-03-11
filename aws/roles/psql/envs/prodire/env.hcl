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
  service     = "psql"
  environment = "prodire"
  account_id  = "000000000000"   # Override per-account in account.hcl

  # EKS OIDC provider - update with values from your EKS cluster
  eks_oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
  eks_oidc_provider_url = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"

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
