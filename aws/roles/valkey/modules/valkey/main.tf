# -----------------------------------------------------------------------------
# Valkey IAM Role Terraform Module
#
# Provisions an IAM role for Valkey (Redis-compatible) containers on EKS,
# with IRSA trust policy and policies for SSM and Secrets Manager access.
#
# Ported from CloudFormation: roles/valkey/files/template.json
#
# The original Ansible role iterated over a `valkey` dict to create multiple
# stacks per valkey instance. In Terraform, we use for_each over the
# `valkey_instances` variable to create one IAM role per instance.
#
# Resources created (per instance):
#   - IAM Role with OIDC-based trust policy (IRSA)
#   - Inline policy for Secrets Manager + SSM parameter access
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })

  # Build the OIDC issuer URL without https:// prefix for condition keys
  oidc_issuer = replace(var.eks_oidc_provider_url, "https://", "")
}

# -----------------------------------------------------------------------------
# IAM Roles - one per valkey instance
# -----------------------------------------------------------------------------

resource "aws_iam_role" "valkey" {
  for_each = toset(var.valkey_instances)

  name = "${upper(var.project)}-${upper(var.environment)}-${upper(each.value)}-${upper(var.role_name)}-EKSServiceIamRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
            "${local.oidc_issuer}:sub" = "system:serviceaccount:${lower(var.project)}-${lower(var.environment)}:${lower(var.project)}-${lower(var.environment)}-${lower(each.value)}-${lower(var.role_name)}-sa"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    valkey_instance = each.value
  })
}

# -----------------------------------------------------------------------------
# Inline policy: Secrets Manager + SSM Parameter Store access
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "secrets_ssm" {
  for_each = toset(var.valkey_instances)

  name = "${upper(var.project)}-${upper(var.environment)}-${upper(each.value)}-${upper(var.role_name)}-SecretsSSMPolicy"
  role = aws_iam_role.valkey[each.value].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "ssm:DescribeParameters",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${lower(var.project)}-${lower(var.environment)}-*"
      }
    ]
  })
}
