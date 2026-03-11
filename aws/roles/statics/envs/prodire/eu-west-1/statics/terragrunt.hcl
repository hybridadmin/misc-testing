# -----------------------------------------------------------------------------
# envs/prodire/eu-west-1/statics/terragrunt.hcl
#
# Deploys Statics resources to prodire in eu-west-1.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/statics.hcl"
  expose = true
}

# Override per-account values as needed
# inputs = {
#   sns_to_email_lambda_arn = "arn:aws:lambda:eu-west-1:<account_id>:function:UTILITIES-PROD-SNStoEmail"
# }
