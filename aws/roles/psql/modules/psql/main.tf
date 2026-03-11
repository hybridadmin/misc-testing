# -----------------------------------------------------------------------------
# PGO Managed Postgres (PSQL) IAM Role Terraform Module
#
# Provisions an IAM role for PGO (Postgres Operator) managed PostgreSQL
# clusters on EKS, with IRSA trust policy scoped to the pgbackrest and
# instance service accounts, plus policies for SSM, Secrets Manager, and
# S3 backup bucket access.
#
# Ported from CloudFormation: roles/psql/files/template.json
#
# Resources created:
#   - IAM Role with OIDC-based trust policy (IRSA) for 3 service accounts
#   - Inline policy for Secrets Manager + SSM parameter access
#   - Inline policy for S3 backup bucket (read/write/delete)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix       = "${upper(var.project)}-${upper(var.environment)}-${upper(var.role_name)}"
  role_name         = "${local.name_prefix}-EKSServiceIamRole"
  psql_cluster_name = "${lower(var.project)}-${lower(var.environment)}-psql"
  namespace         = "${lower(var.project)}-${lower(var.environment)}"

  # Build the OIDC issuer URL without https:// prefix for condition keys
  oidc_issuer = replace(var.eks_oidc_provider_url, "https://", "")

  # PGO creates three service accounts per cluster
  service_accounts = [
    "system:serviceaccount:${local.namespace}:${local.psql_cluster_name}-instance",
    "system:serviceaccount:${local.namespace}:${local.psql_cluster_name}-pgbackrest",
    "system:serviceaccount:${local.namespace}:${local.psql_cluster_name}-repohost",
  ]

  # S3 backup bucket name convention
  backup_bucket = "postgres-operator-${lower(var.environment)}-backups-${data.aws_caller_identity.current.account_id}"

  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })
}

# -----------------------------------------------------------------------------
# IAM Role with IRSA trust policy (3 service accounts)
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
            "${local.oidc_issuer}:sub" = local.service_accounts
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
# Inline policy: S3 backup bucket access (read/write/delete for pgbackrest)
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "s3_backup" {
  name = "${local.name_prefix}-S3BackupPolicy"
  role = aws_iam_role.eks_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObjectAcl",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
        ]
        Resource = "arn:aws:s3:::${local.backup_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.backup_bucket}"
      }
    ]
  })
}
