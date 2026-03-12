# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/root_audit_trail/terragrunt.hcl
#
# Deploys Root Audit Trail to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/root_audit_trail.hcl"
  expose = true
}
