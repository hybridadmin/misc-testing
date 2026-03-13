locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
}

terraform {
  source = "${get_repo_root()}/01_bootstrap/modules/build-vpc"
}

inputs = {
  name_prefix          = "CICD-BUILD"
  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidr   = "10.0.10.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = false

  ssm_parameter_paths = [
    "arn:aws:ssm:eu-west-1:*:parameter/private_key_orgadmin",
    "arn:aws:ssm:eu-west-1:*:parameter/private-key-orgadmin",
  ]

  software_bucket_name = "myorg-ami-software"

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "build-vpc"
  }
}
