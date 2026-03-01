###############################################################################
# AWS IAM Identity Center (SSO) Configuration Module
#
# This module configures IAM Identity Center in the AWS Organizations master
# account and sets up Google Workspace as an external identity provider (IdP)
# via SAML 2.0. It also manages SCIM provisioning for automatic user/group sync.
#
# IMPORTANT: IAM Identity Center can only be enabled ONCE per AWS Organization,
# and it must be done from the management (master) account.
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

# Fetch the existing SSO instance. AWS creates one when you enable Identity
# Center in the console. If you have not enabled it yet, do so manually first
# (Organizations > Services > IAM Identity Center) or use the resource below.
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# Current AWS account (master/management)
data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "current" {}

# ---------------------------------------------------------------------------
# SSO Groups — synced from Google Workspace via SCIM, but we declare them
# here so Terraform can reference them for permission set assignments.
#
# NOTE: If you use SCIM auto-provisioning, groups are created automatically
# by Google. In that case, use data sources instead of resources. The
# approach below creates them in Identity Store directly and is compatible
# with both manual and SCIM flows.
# ---------------------------------------------------------------------------

resource "aws_identitystore_group" "groups" {
  for_each = { for g in var.sso_groups : g.name => g }

  identity_store_id = local.identity_store_id
  display_name      = each.value.name
  description       = each.value.description
}

# ---------------------------------------------------------------------------
# SSO Users — optional, for cases where you want to pre-create users
# ---------------------------------------------------------------------------

resource "aws_identitystore_user" "users" {
  for_each = { for u in var.sso_users : u.user_name => u }

  identity_store_id = local.identity_store_id
  user_name         = each.value.user_name
  display_name      = each.value.display_name

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    primary = true
    type    = "work"
  }
}

# ---------------------------------------------------------------------------
# Group Membership
# ---------------------------------------------------------------------------

resource "aws_identitystore_group_membership" "memberships" {
  for_each = { for m in var.group_memberships : "${m.group_name}-${m.user_name}" => m }

  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.groups[each.value.group_name].group_id
  member_id         = aws_identitystore_user.users[each.value.user_name].user_id
}
