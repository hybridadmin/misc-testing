# -----------------------------------------------------------------------------
# envs/systest/eu-west-1/logsalarm/terragrunt.hcl
#
# Deploys the LogsAlarm Lambda to systest in eu-west-1 (management account).
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/logsalarm.hcl"
  expose = true
}
