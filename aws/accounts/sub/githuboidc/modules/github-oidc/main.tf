# -----------------------------------------------------------------------------
# GitHub OIDC Terraform Module
#
# Configures an AWS IAM OIDC Identity Provider for GitHub Actions and creates
# IAM roles that GitHub Actions workflows can assume via OIDC federation.
#
# This eliminates the need for long-lived AWS access keys in GitHub Actions
# CI/CD pipelines.
#
# Resources created:
#   - IAM OIDC Identity Provider (for GitHub Actions)
#   - IAM Role(s) with trust policies scoped to specific GitHub repos/branches
#   - IAM Role policy attachments for the assumed roles
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"

  # GitHub OIDC provider URL (without https://)
  github_oidc_url = "token.actions.githubusercontent.com"

  common_tags = merge(
    {
      project     = lower(var.project)
      environment = lower(var.environment)
      service     = lower(var.service)
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# TLS Certificate - fetch GitHub's OIDC thumbprint
# -----------------------------------------------------------------------------

data "tls_certificate" "github" {
  url = "https://${local.github_oidc_url}"
}

# -----------------------------------------------------------------------------
# IAM OIDC Identity Provider
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://${local.github_oidc_url}"

  client_id_list = var.oidc_client_ids

  thumbprint_list = [
    data.tls_certificate.github.certificates[0].sha1_fingerprint,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-oidc"
  })
}

# -----------------------------------------------------------------------------
# IAM Roles for GitHub Actions workflows
#
# Each role is scoped to specific GitHub orgs/repos/branches via the
# trust policy's condition on the "sub" claim from the OIDC token.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  for_each = { for role in var.github_actions_roles : role.name => role }

  name        = "${local.name_prefix}-${each.value.name}"
  description = try(each.value.description, "GitHub Actions OIDC role for ${each.value.name}")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.github_oidc_url}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${local.github_oidc_url}:sub" = each.value.subject_claims
          }
        }
      }
    ]
  })

  max_session_duration = try(each.value.max_session_duration, 3600)

  tags = merge(local.common_tags, {
    Name              = "${local.name_prefix}-${each.value.name}"
    github_repository = join(",", each.value.subject_claims)
  })
}

# -----------------------------------------------------------------------------
# Managed policy attachments
# -----------------------------------------------------------------------------

locals {
  # Flatten the role -> managed_policy_arns mapping for for_each
  role_policy_attachments = flatten([
    for role in var.github_actions_roles : [
      for policy_arn in try(role.managed_policy_arns, []) : {
        role_name  = role.name
        policy_arn = policy_arn
      }
    ]
  ])
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  for_each = {
    for rpa in local.role_policy_attachments :
    "${rpa.role_name}-${rpa.policy_arn}" => rpa
  }

  role       = aws_iam_role.github_actions[each.value.role_name].name
  policy_arn = each.value.policy_arn
}

# -----------------------------------------------------------------------------
# Inline policies
# -----------------------------------------------------------------------------

locals {
  # Flatten the role -> inline_policies mapping for for_each
  role_inline_policies = flatten([
    for role in var.github_actions_roles : [
      for policy in try(role.inline_policies, []) : {
        role_name   = role.name
        policy_name = policy.name
        policy_json = policy.policy
      }
    ]
  ])
}

resource "aws_iam_role_policy" "github_actions" {
  for_each = {
    for rip in local.role_inline_policies :
    "${rip.role_name}-${rip.policy_name}" => rip
  }

  name   = each.value.policy_name
  role   = aws_iam_role.github_actions[each.value.role_name].id
  policy = each.value.policy_json
}
