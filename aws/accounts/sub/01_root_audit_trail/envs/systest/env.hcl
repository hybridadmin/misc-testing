# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "root-audit-trail"
  environment = "systest"
  account_id  = "000000000000"

  # Email addresses to receive root sign-in notifications
  email_addresses = [
    "security-alerts@example.com",
  ]
}
