include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/cdk-bootstrap.hcl"
  expose = true
}

# Override inputs for this account if needed:
# inputs = {}
