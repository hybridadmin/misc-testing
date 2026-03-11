###############################################################################
# Cross-Account Roles
# Admin and read-only cross-account IAM roles with MFA requirement.
###############################################################################

# ------------------------------------------------------------------------------
# Cross Account Admin Access Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cross_account_admin" {
  name = "CrossAccountAdminAccess"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = "arn:aws:iam::${var.identity_account_id}:root"
      }
      Condition = {
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
      }
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AdministratorAccess"
  ]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Cross Account Read Access Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cross_account_read" {
  name = "CrossAccountReadAccess"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = "arn:aws:iam::${var.identity_account_id}:root"
      }
      Condition = {
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
      }
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/ReadOnlyAccess"
  ]

  tags = var.tags
}

resource "aws_iam_role_policy" "deny_secrets" {
  name = "deny-read-of-secret-parameters"
  role = aws_iam_role.cross_account_read.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Action = [
        "secretsmanager:GetSecretValue",
        "ssm:GetParameter",
        "ssm:GetParameters"
      ]
      Resource = "*"
    }]
  })
}
