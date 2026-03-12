###############################################################################
# Workload Production Account — SSO Account Assignments
#
# Production has more restrictive permissions:
#   - Developers get ReadOnly (not DeveloperAccess)
#   - Only Admins and DevOps get write access
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
  config_path = "${get_repo_root()}/envs/master/eu-west-1/sso-configuration"

  mock_outputs = {
    sso_instance_arn  = "arn:aws:sso:::instance/ssoins-0000000000000000"
    identity_store_id = "d-0000000000"
  }
}

dependency "permission_sets" {
  config_path = "${get_repo_root()}/envs/master/eu-west-1/sso-permission-sets"

  mock_outputs = {
    permission_set_arns = {
      AdministratorAccess = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000001"
      ReadOnlyAccess      = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000003"
      DevOpsAccess        = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0000000000000004"
    }
  }
}

# ---------------------------------------------------------------------------
# Override provider to use the MASTER account profile
# ---------------------------------------------------------------------------

generate "provider_override" {
  path      = "provider_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region  = "eu-west-1"
      profile = "master-admin"

      default_tags {
        tags = {
          Project     = "google-sso"
          Environment = "workload-prod"
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
  prod_account_id = "444444444444" # <-- REPLACE with your production account ID
}

inputs = {
  account_assignments = [
    # Admins get full access (break-glass)
    {
      account_id          = local.prod_account_id
      permission_set_name = "AdministratorAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-Admins"
    },
    # Developers get READ-ONLY in production (safer)
    {
      account_id          = local.prod_account_id
      permission_set_name = "ReadOnlyAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-Developers"
    },
    # DevOps gets devops access for infrastructure management
    {
      account_id          = local.prod_account_id
      permission_set_name = "DevOpsAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-DevOps"
    },
    # ReadOnly group
    {
      account_id          = local.prod_account_id
      permission_set_name = "ReadOnlyAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-ReadOnly"
    },
    # Security audit
    {
      account_id          = local.prod_account_id
      permission_set_name = "SecurityAudit"
      principal_type      = "GROUP"
      principal_name      = "AWS-SecurityAudit"
    },
    # Billing (production costs matter most)
    {
      account_id          = local.prod_account_id
      permission_set_name = "BillingAccess"
      principal_type      = "GROUP"
      principal_name      = "AWS-Billing"
    },
  ]
}
