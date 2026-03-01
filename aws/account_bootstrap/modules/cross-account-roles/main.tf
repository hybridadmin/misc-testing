###############################################################################
# Data Sources
###############################################################################

data "aws_iam_policy_document" "cross_account_assume_role" {
  statement {
    sid     = "AllowCrossAccountAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.trusted_account_id}:root"]
    }

    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

data "aws_iam_policy_document" "deny_secret_access" {
  statement {
    sid    = "DenyReadOfSecretParameters"
    effect = "Deny"

    actions = [
      "secretsmanager:GetSecretValue",
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = ["*"]
  }
}

###############################################################################
# Cross-Account Admin Role
###############################################################################

resource "aws_iam_role" "admin" {
  name                 = var.admin_role_name
  path                 = var.role_path
  max_session_duration = var.max_session_duration
  assume_role_policy   = data.aws_iam_policy_document.cross_account_assume_role.json

  tags = merge(
    var.tags,
    {
      Name = var.admin_role_name
    },
  )
}

resource "aws_iam_role_policy_attachment" "admin_administrator_access" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

###############################################################################
# Cross-Account Read-Only Role
###############################################################################

resource "aws_iam_role" "read_only" {
  name                 = var.read_only_role_name
  path                 = var.role_path
  max_session_duration = var.max_session_duration
  assume_role_policy   = data.aws_iam_policy_document.cross_account_assume_role.json

  tags = merge(
    var.tags,
    {
      Name = var.read_only_role_name
    },
  )
}

resource "aws_iam_role_policy_attachment" "read_only_access" {
  role       = aws_iam_role.read_only.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "deny_secret_access" {
  name   = "deny-read-of-secret-parameters"
  role   = aws_iam_role.read_only.id
  policy = data.aws_iam_policy_document.deny_secret_access.json
}
