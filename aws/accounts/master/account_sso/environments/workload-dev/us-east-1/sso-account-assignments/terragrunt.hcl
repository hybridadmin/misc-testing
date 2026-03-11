###############################################################################
# Workload Dev Account — SSO Account Assignments
#
# Assigns SSO groups to the development AWS account with specific
# permission sets. All SSO operations are performed against the master
# account's IAM Identity Center — this Terragrunt config uses the master
# account's AWS profile to make the assignments.
#
# NOTE: The AWS provider MUST target the master/management account because
# that is where IAM Identity Center lives. The account_id in the assignments
# refers to the TARGET account that users will access.
###############################################################################

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/sso-account-assignments.hcl"
  expose = true
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

dependency "sso_config" {
  config_path = "${get_repo_root()}/environments/master/us-east-1/sso-configuration"

  mock_outputs = {
    sso_instance_arn  = "arn:aws:sso:::instance/ssoins-0000000000000000"
    identity_store_id = "d-0000000000"
  }
}

dependency "permission_sets" {
  config_path = "${get_repo_root()}/environments/master/us-east-1/sso-permission-sets"

  mock_outputs = {
    permission_set_arns = {
      AdministratorAccess = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000001"
      DeveloperAccess     = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000002"
      ReadOnlyAccess      = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000003"
    }
  }
}

# ---------------------------------------------------------------------------
# IMPORTANT: Override provider to use the MASTER account profile
#
# Account assignments must be made from the management account.
# ---------------------------------------------------------------------------

generate "provider_override" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region  = "us-east-1"
      profile = "master-admin"   # <-- Must be the master account profile

      default_tags {
        tags = {
          Project     = "google-sso"
          Environment = "workload-dev"
          ManagedBy   = "terraform"
        }
      }
    }
  EOF
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

locals {
  dev_account_id = "222222222222" # <-- REPLACE with your dev account ID
}

inputs = {
  account_assignments = [
    # Admins get full access
    {
      account_id          = local.dev_account_id
      permission_set_name = "AdministratorAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-Admins"
    },
    # Developers get developer access
    {
      account_id          = local.dev_account_id
      permission_set_name = "DeveloperAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-Developers"
    },
    # DevOps gets devops access
    {
      account_id          = local.dev_account_id
      permission_set_name = "DevOpsAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-DevOps"
    },
    # ReadOnly group gets read-only access
    {
      account_id          = local.dev_account_id
      permission_set_name = "ReadOnlyAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-ReadOnly"
    },
    # Security audit
    {
      account_id          = local.dev_account_id
      permission_set_name = "SecurityAudit"
      principal_type      = "GROUP"
      principal_name      = "AWS-SecurityAudit"
    },
  ]
}
