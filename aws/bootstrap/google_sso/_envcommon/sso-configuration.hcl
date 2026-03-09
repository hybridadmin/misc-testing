###############################################################################
# Common Configuration — SSO Configuration
#
# Shared terragrunt configuration for the SSO configuration module.
# This is included by environment-specific terragrunt.hcl files.
###############################################################################

terraform {
  source = "${get_repo_root()}/modules/sso-configuration"
}
