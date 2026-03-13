# -----------------------------------------------------------------------------
# envs/env.hcl
#
# Environment-level configuration for the generate_account_dirs.sh script.
#
# target_ou_ids  - OUs to scan for active accounts (sub-accounts only;
#                  the audit and management accounts are auto-skipped).
# target_regions - Regions to deploy to. The FIRST region is treated as
#                  the primary region (gets all modules). Additional regions
#                  only get common-resources and config-recorder.
# -----------------------------------------------------------------------------

locals {
  target_ou_ids = [
    "ou-xxxx-cccccccc", # Production OU
    "ou-xxxx-dddddddd", # Development OU
    "ou-xxxx-bbbbbbbb", # Services OU
  ]

  target_regions = [
    "eu-west-1",  # Primary region (all modules)
    "af-south-1", # Secondary region (common-resources + config-recorder only)
  ]
}
