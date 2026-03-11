# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "statics"
  environment = "systest"
  account_id  = "000000000000"

  # SNS-to-Email Lambda function ARN (set to "" to skip SNS subscriptions)
  sns_to_email_lambda_arn = ""

  # Logs bucket lifecycle
  logs_expiration_days = 180
}
