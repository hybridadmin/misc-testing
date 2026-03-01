###############################################################################
# SSO Account Assignments Module
#
# Assigns SSO groups and/or users to specific AWS accounts with a given
# permission set. This is the module that "connects the dots" between:
#   - Google Workspace groups (synced via SCIM to IAM Identity Store)
#   - Permission sets (defined in the sso-permission-sets module)
#   - Target AWS accounts
#
# This module can be deployed per-account or with a list of assignments
# covering multiple accounts.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# ---------------------------------------------------------------------------
# Look up groups by display name from the Identity Store
# ---------------------------------------------------------------------------

data "aws_identitystore_group" "groups" {
  for_each = toset(local.all_group_names)

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.value
    }
  }
}

locals {
  all_group_names = distinct([
    for a in var.account_assignments : a.principal_name
    if a.principal_type == "GROUP"
  ])

  all_user_names = distinct([
    for a in var.account_assignments : a.principal_name
    if a.principal_type == "USER"
  ])
}

# ---------------------------------------------------------------------------
# Look up users by user name from the Identity Store (if any user assignments)
# ---------------------------------------------------------------------------

data "aws_identitystore_user" "users" {
  for_each = toset(local.all_user_names)

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = each.value
    }
  }
}

# ---------------------------------------------------------------------------
# Look up permission sets by name
# ---------------------------------------------------------------------------

data "aws_ssoadmin_permission_set" "this" {
  for_each = toset(distinct([for a in var.account_assignments : a.permission_set_name]))

  instance_arn = local.sso_instance_arn
  name         = each.value
}

# ---------------------------------------------------------------------------
# Account Assignments
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = {
    for a in var.account_assignments :
    "${a.account_id}-${a.principal_type}-${a.principal_name}-${a.permission_set_name}" => a
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.this[each.value.permission_set_name].arn
  target_id          = each.value.account_id
  target_type        = "AWS_ACCOUNT"
  principal_type     = each.value.principal_type

  principal_id = (
    each.value.principal_type == "GROUP"
    ? data.aws_identitystore_group.groups[each.value.principal_name].group_id
    : data.aws_identitystore_user.users[each.value.principal_name].user_id
  )
}
