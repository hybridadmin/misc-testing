# -----------------------------------------------------------------------------
# Cross-account roles -- Dev
#
# Inherits everything from the envcommon config.
# Add account-specific overrides in the `inputs` block below.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/cross-account-roles.hcl"
  expose = true
}

# Override inputs for this account if needed:
# inputs = {}
