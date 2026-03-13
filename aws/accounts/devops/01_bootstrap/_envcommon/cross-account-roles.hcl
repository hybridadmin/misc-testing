locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
}

terraform {
  source = "${get_repo_root()}/01_bootstrap/modules/cross-account-roles"
}

inputs = {
  devops_account_id = "000000000000" # TODO: Replace with your DevOps account ID

  packer_account_ids = [
    # "111111111111", # Add additional account IDs that run Packer builds
  ]

  deployment_role_name          = "ORGRoleForDevopsDeployment"
  cfn_execution_policy_name     = "ORGPolicyForCfnExecution"
  stackset_execution_role_name  = "AWSCloudFormationStackSetExecutionRole"
  stackset_admin_role_name      = "AWSCloudFormationStackSetAdministrationRole"

  factory_profile_prefix = "CICD-BUILD"
  factory_role_prefix    = "CICD-BUILD"

  devops_kms_key_arns = [
    # "arn:aws:kms:eu-west-1:000000000000:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    # "arn:aws:kms:af-south-1:000000000000:key/ffffffff-1111-2222-3333-444444444444",
  ]

  deployment_bucket_regions = ["eu-west-1", "af-south-1"]
  cdk_qualifier             = "hnb659fds"
  configuration_bucket_name = "myorg-build-configuration"

  additional_cfn_via_services = ["af-south-1"]

  tags = {
    AccountName = local.account_name
    AccountId   = local.account_id
    Module      = "cross-account-roles"
  }
}
