# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/root_audit_trail/terragrunt.hcl
#
# Deploys Root Audit Trail to prodire in eu-west-1.
#
# For multi-account deployment across OUs, create a directory per target
# account using generate_account_dirs.sh, or use run-all with account
# overrides.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/root_audit_trail.hcl"
  expose = true
}
