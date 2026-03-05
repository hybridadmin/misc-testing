# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/logsalarm/terragrunt.hcl
#
# Deploys the LogsAlarm Lambda to prodire in eu-west-1.
#
# For multi-account deployment across OUs, create a directory per target
# account, or use run-all with account overrides. See account_overrides
# below for an example of how to target a specific account.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/logsalarm.hcl"
  expose = true
}

# Override account_id if deploying to a specific account different from env.hcl
# inputs = {
#   # Uncomment and set to target a specific account
# }
