################################################################################
# KMS Key for Shared AMI Encryption
#
# Ported from: stacksets/kms-keys.yml
#
# Creates a KMS key and alias for encrypting AMIs shared across the
# AWS Organization. The key policy grants:
#   1. Full access to the account root
#   2. Admin access to the specified admin role
#   3. Encrypt/decrypt access to all principals in the organization
#   4. Grant management to the organization
################################################################################

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms_key_policy" {
  # Statement 1: Account root full access
  statement {
    sid    = "EnableRootAccountAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Statement 2: Admin role key management
  statement {
    sid    = "AllowKeyAdministration"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.admin_role_name}"]
    }
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  # Statement 3: Organization-wide encrypt/decrypt
  statement {
    sid    = "AllowOrganizationEncryptDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organization_id]
    }
  }

  # Statement 4: Organization-wide grant management
  statement {
    sid    = "AllowOrganizationGrantManagement"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organization_id]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "ami_encryption" {
  description             = var.key_description
  enable_key_rotation     = var.enable_key_rotation
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.kms_key_policy.json

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-${var.alias_name}"
  })
}

resource "aws_kms_alias" "ami_encryption" {
  name          = "alias/${var.project}-${var.environment}-${var.alias_name}"
  target_key_id = aws_kms_key.ami_encryption.key_id
}
