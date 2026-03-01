# -----------------------------------------------------------------------------
# KMS keys -- Prod
#
# Inherits everything from the envcommon config.
# Add account-specific overrides in the `inputs` block below.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/kms-keys.hcl"
  expose = true
}

# Override inputs for this account if needed.
# Example: use a longer deletion window for prod:
# inputs = {
#   deletion_window_in_days = 30
# }
