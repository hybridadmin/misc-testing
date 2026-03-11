# -----------------------------------------------------------------------------
# EKS Service IAM Role Terraform Module
#
# Provisions an IAM role for EKS services with IRSA (IAM Roles for Service
# Accounts) trust policy, plus inline policies for Secrets Manager, SSM,
# SSM Agent, and S3 access.
#
# Ported from CloudFormation: roles/eksservice/files/template.json
#
# Resources created:
#   - IAM Role with OIDC-based trust policy (IRSA)
#   - Inline policy for Secrets Manager + SSM parameter access
#   - Inline policy for SSM Agent messaging channels
#   - Inline policy for project S3 bucket access
#   - Additional IAM policies for each extra S3 bucket (dynamic)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}-${upper(var.service)}"
  role_name   = "${local.name_prefix}-EKSServiceIamRole"

  # Build the OIDC issuer URL without https:// prefix for condition keys
  oidc_issuer = replace(var.eks_oidc_provider_url, "https://", "")

  # Service account name follows the convention: <project>-<environment>-<service>-sa
  service_account = "${lower(var.project)}-${lower(var.environment)}:${lower(var.project)}-${lower(var.environment)}-${lower(var.service)}-sa"

  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })
}

# -----------------------------------------------------------------------------
# IAM Role with IRSA trust policy
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_service" {
  name = local.role_name

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
            "${local.oidc_issuer}:sub" = "system:serviceaccount:${local.service_account}"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Inline policy: Secrets Manager + SSM Parameter Store access
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "secrets_ssm" {
  name = "${local.name_prefix}-SecretsSSMPolicy"
  role = aws_iam_role.eks_service.id

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

# -----------------------------------------------------------------------------
# Inline policy: SSM Agent messaging channels
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "ssm_agent" {
  name = "${local.name_prefix}-SSMAgentPolicy"
  role = aws_iam_role.eks_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSsmAgent"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Inline policy: Project S3 bucket access
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "project_s3" {
  name = "${local.name_prefix}-ProjectS3Policy"
  role = aws_iam_role.eks_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${lower(var.project)}-${lower(var.environment)}-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::${lower(var.project)}-${lower(var.environment)}-${data.aws_caller_identity.current.account_id}/*",
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Additional S3 bucket policies (one per extra bucket)
#
# The original CloudFormation used Fn::ForEach with AWS::LanguageExtensions
# to iterate over a comma-delimited list of bucket names.
# In Terraform, we use for_each over the s3_buckets variable.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "extra_s3" {
  for_each = toset(var.s3_buckets)

  name = "S3policy-${each.value}"
  role = aws_iam_role.eks_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${each.value}",
          "arn:aws:s3:::${each.value}/*",
        ]
      }
    ]
  })
}
