# -----------------------------------------------------------------------------
# _envcommon/psql.hcl
#
# Shared Terragrunt configuration for the psql component.
# Included by each leaf-level terragrunt.hcl in envs/<env>/<region>/psql/
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/psql/modules/psql"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  eks_oidc_provider_arn = local.env_vars.locals.eks_oidc_provider_arn
  eks_oidc_provider_url = local.env_vars.locals.eks_oidc_provider_url
}
