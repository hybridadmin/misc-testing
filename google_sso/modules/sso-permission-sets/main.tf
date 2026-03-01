###############################################################################
# SSO Permission Sets Module
#
# Creates permission sets in IAM Identity Center. Permission sets define
# what level of access a user/group gets when they assume a role in a
# target AWS account. These are created in the master account and then
# assigned to specific accounts via the sso-account-assignments module.
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
  sso_instance_arn = tolist(data.aws_ssoadmin_instances.this.arns)[0]
}

# ---------------------------------------------------------------------------
# Permission Sets
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "this" {
  for_each = { for ps in var.permission_sets : ps.name => ps }

  name             = each.value.name
  description      = each.value.description
  instance_arn     = local.sso_instance_arn
  session_duration = each.value.session_duration
  relay_state      = lookup(each.value, "relay_state", null)

  tags = merge(var.tags, lookup(each.value, "tags", {}))
}

# ---------------------------------------------------------------------------
# AWS Managed Policy Attachments
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = {
    for pair in local.managed_policy_pairs : "${pair.ps_name}-${pair.policy_arn}" => pair
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps_name].arn
  managed_policy_arn = each.value.policy_arn
}

locals {
  managed_policy_pairs = flatten([
    for ps in var.permission_sets : [
      for policy_arn in lookup(ps, "managed_policy_arns", []) : {
        ps_name    = ps.name
        policy_arn = policy_arn
      }
    ]
  ])
}

# ---------------------------------------------------------------------------
# Inline Policy Attachments
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set_inline_policy" "this" {
  for_each = {
    for ps in var.permission_sets : ps.name => ps
    if lookup(ps, "inline_policy", null) != null
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  inline_policy      = each.value.inline_policy
}

# ---------------------------------------------------------------------------
# Customer Managed Policy Attachments
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_customer_managed_policy_attachment" "this" {
  for_each = {
    for pair in local.customer_managed_policy_pairs : "${pair.ps_name}-${pair.policy_name}" => pair
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.ps_name].arn

  customer_managed_policy_reference {
    name = each.value.policy_name
    path = each.value.policy_path
  }
}

locals {
  customer_managed_policy_pairs = flatten([
    for ps in var.permission_sets : [
      for policy in lookup(ps, "customer_managed_policies", []) : {
        ps_name     = ps.name
        policy_name = policy.name
        policy_path = lookup(policy, "path", "/")
      }
    ]
  ])
}

# ---------------------------------------------------------------------------
# Permissions Boundary
# ---------------------------------------------------------------------------

resource "aws_ssoadmin_permissions_boundary_attachment" "managed" {
  for_each = {
    for ps in var.permission_sets : ps.name => ps
    if lookup(ps, "permissions_boundary_managed_policy_arn", null) != null
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn

  permissions_boundary {
    managed_policy_arn = each.value.permissions_boundary_managed_policy_arn
  }
}

resource "aws_ssoadmin_permissions_boundary_attachment" "customer_managed" {
  for_each = {
    for ps in var.permission_sets : ps.name => ps
    if lookup(ps, "permissions_boundary_customer_managed_policy", null) != null
  }

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn

  permissions_boundary {
    customer_managed_policy_reference {
      name = each.value.permissions_boundary_customer_managed_policy.name
      path = lookup(each.value.permissions_boundary_customer_managed_policy, "path", "/")
    }
  }
}
