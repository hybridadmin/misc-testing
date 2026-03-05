# Override region for backup account
locals {
  project     = "admin"
  environment = "prod"
  aws_region  = "us-west-2"

  # Re-export all variables from parent env.hcl that children may need
  devops_account_id  = "555555555555"
  backup_account_id  = "777777777777"
  organization_id    = "o-pfayzcebx5"
  production_ou_path = "o-pfayzcebx5/r-zkdv/ou-zkdv-a0k0yvv1"
}
