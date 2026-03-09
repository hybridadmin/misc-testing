###############################################################################
# Common Configuration — SSO Account Assignments
#
# Shared terragrunt configuration for the SSO account assignments module.
###############################################################################

terraform {
  source = "${get_repo_root()}/modules/sso-account-assignments"
}
