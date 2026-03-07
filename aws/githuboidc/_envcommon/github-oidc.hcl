# -----------------------------------------------------------------------------
# _envcommon/github-oidc.hcl
#
# Shared Terragrunt configuration for the github-oidc component.
# Included by each leaf-level terragrunt.hcl in
#   envs/<env>/<region>/github-oidc/
#   envs/<env>/<region>/<account_id>/github-oidc/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/githuboidc/modules/github-oidc"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  github_actions_roles = local.env_vars.locals.github_actions_roles
}
