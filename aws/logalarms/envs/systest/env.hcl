# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project            = "devops"
  service            = "logsalarm"
  environment        = "systest"
  account_id         = "000000000000"
  log_retention_days = 30
}
