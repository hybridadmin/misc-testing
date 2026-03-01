###############################################################################
# Common Configuration — SSO Permission Sets
#
# Shared terragrunt configuration for the SSO permission sets module.
###############################################################################

terraform {
  source = "${get_repo_root()}/modules/sso-permission-sets"
}
