# -----------------------------------------------------------------------------
# envs/prodire/af-south-1/logsalarm/terragrunt.hcl
#
# Deploys the LogsAlarm Lambda to prodire in af-south-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/logsalarm.hcl"
  expose = true
}
