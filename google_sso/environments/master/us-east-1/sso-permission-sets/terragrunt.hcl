###############################################################################
# Master Account — SSO Permission Sets
#
# Defines all permission sets available across the organization.
# Permission sets are created in the master account and then assigned
# to specific accounts in the sso-account-assignments module.
#
# IMPORTANT: Deploy this AFTER sso-configuration and BEFORE
# sso-account-assignments.
###############################################################################

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders())}/_envcommon/sso-permission-sets.hcl"
  expose = true
}

# ---------------------------------------------------------------------------
# Dependencies — Permission sets need the SSO instance to exist
# ---------------------------------------------------------------------------

dependency "sso_config" {
  config_path = "../sso-configuration"

  mock_outputs = {
    sso_instance_arn  = "arn:aws:sso:::instance/ssoins-0000000000000000"
    identity_store_id = "d-0000000000"
  }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

inputs = {
  permission_sets = [
    # -----------------------------------------------------------------------
    # AdministratorAccess — Full admin, use sparingly
    # -----------------------------------------------------------------------
    {
      name             = "AdministratorAccess"
      description      = "Full administrator access. Restricted to AWS-Admins group."
      session_duration = "PT4H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/AdministratorAccess"
      ]
    },

    # -----------------------------------------------------------------------
    # PowerUserAccess — Everything except IAM/Org management
    # -----------------------------------------------------------------------
    {
      name             = "PowerUserAccess"
      description      = "Full access except IAM and Organizations management."
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess"
      ]
    },

    # -----------------------------------------------------------------------
    # DeveloperAccess — Common developer permissions
    # -----------------------------------------------------------------------
    {
      name             = "DeveloperAccess"
      description      = "Developer access with permissions for common AWS services (ECS, Lambda, S3, DynamoDB, etc.)"
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess"
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyIAMChanges"
            Effect = "Deny"
            Action = [
              "iam:CreateUser",
              "iam:DeleteUser",
              "iam:CreateRole",
              "iam:DeleteRole",
              "iam:AttachRolePolicy",
              "iam:DetachRolePolicy",
              "iam:PutRolePolicy",
              "iam:DeleteRolePolicy",
              "organizations:*",
              "account:*",
              "sso:*",
              "sso-directory:*",
            ]
            Resource = "*"
          }
        ]
      })
    },

    # -----------------------------------------------------------------------
    # ReadOnlyAccess — View-only access
    # -----------------------------------------------------------------------
    {
      name             = "ReadOnlyAccess"
      description      = "Read-only access to all AWS resources. Safe for auditors and observers."
      session_duration = "PT12H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/ReadOnlyAccess"
      ]
    },

    # -----------------------------------------------------------------------
    # SecurityAudit — Security-focused read access
    # -----------------------------------------------------------------------
    {
      name             = "SecurityAudit"
      description      = "Security audit access — read-only with enhanced security service visibility."
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/SecurityAudit",
        "arn:aws:iam::aws:policy/ReadOnlyAccess"
      ]
    },

    # -----------------------------------------------------------------------
    # BillingAccess — Cost and billing management
    # -----------------------------------------------------------------------
    {
      name             = "BillingAccess"
      description      = "Access to AWS billing, budgets, and cost management."
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/job-function/Billing",
        "arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess"
      ]
    },

    # -----------------------------------------------------------------------
    # DevOpsAccess — Infrastructure management
    # -----------------------------------------------------------------------
    {
      name             = "DevOpsAccess"
      description      = "DevOps/infrastructure access for CI/CD, containers, networking, and IaC."
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/PowerUserAccess"
      ]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "AllowIAMRoleManagement"
            Effect = "Allow"
            Action = [
              "iam:CreateRole",
              "iam:DeleteRole",
              "iam:AttachRolePolicy",
              "iam:DetachRolePolicy",
              "iam:PutRolePolicy",
              "iam:DeleteRolePolicy",
              "iam:UpdateAssumeRolePolicy",
              "iam:TagRole",
              "iam:UntagRole",
              "iam:GetRole",
              "iam:ListRoles",
              "iam:ListRolePolicies",
              "iam:ListAttachedRolePolicies",
              "iam:PassRole",
              "iam:CreateInstanceProfile",
              "iam:DeleteInstanceProfile",
              "iam:AddRoleToInstanceProfile",
              "iam:RemoveRoleFromInstanceProfile",
              "iam:CreateServiceLinkedRole",
            ]
            Resource = "*"
          },
          {
            Sid    = "DenySSAndOrgChanges"
            Effect = "Deny"
            Action = [
              "organizations:*",
              "account:*",
              "sso:*",
              "sso-directory:*",
              "iam:CreateUser",
              "iam:DeleteUser",
            ]
            Resource = "*"
          }
        ]
      })
    },

    # -----------------------------------------------------------------------
    # DatabaseAdmin — Database management access
    # -----------------------------------------------------------------------
    {
      name             = "DatabaseAdmin"
      description      = "Database administration access (RDS, DynamoDB, ElastiCache, Redshift)."
      session_duration = "PT8H"
      managed_policy_arns = [
        "arn:aws:iam::aws:policy/job-function/DatabaseAdministrator"
      ]
    },
  ]
}
