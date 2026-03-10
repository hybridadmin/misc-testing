# -----------------------------------------------------------------------------
# _envcommon/bastion-efs.hcl
#
# Shared Terragrunt configuration for the bastion-efs component.
# Included by each leaf-level terragrunt.hcl for bastion-efs deployments.
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/bastion/modules/bastion-efs"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  vpc_id            = local.env_vars.locals.vpc_id
  vpc_cidr          = local.env_vars.locals.vpc_cidr
  public_subnet_ids = local.env_vars.locals.public_subnet_ids
}
