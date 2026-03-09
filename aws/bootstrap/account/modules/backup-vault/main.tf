###############################################################################
# Data Sources
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

###############################################################################
# KMS Key for Backup Vault Encryption
###############################################################################

resource "aws_kms_key" "backup" {
  description             = var.kms_key_description
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  is_enabled              = true

  policy = data.aws_iam_policy_document.kms_key_policy.json

  tags = merge(
    var.tags,
    {
      Name = var.name
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.backup.key_id
}

data "aws_iam_policy_document" "kms_key_policy" {
  # Allow account root full access to manage the key
  statement {
    sid    = "AllowAccountRootFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Allow the cross-account admin role to administer the key
  statement {
    sid    = "AllowCrossAccountAdminKeyManagement"
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

  # Allow access through AWS Backup for authorised principals
  statement {
    sid    = "AllowBackupServiceAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["backup.${data.aws_region.current.name}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = concat([data.aws_caller_identity.current.account_id], var.backup_source_account_ids)
    }
  }
}

###############################################################################
# AWS Backup Vault
###############################################################################

resource "aws_backup_vault" "this" {
  name        = var.name
  kms_key_arn = aws_kms_key.backup.arn

  tags = merge(
    var.tags,
    {
      Name = var.name
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_backup_vault_policy" "this" {
  backup_vault_name = aws_backup_vault.this.name

  policy = data.aws_iam_policy_document.vault_access_policy.json
}

data "aws_iam_policy_document" "vault_access_policy" {
  statement {
    sid    = "AllowOrganisationCopyIntoVault"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["backup:CopyIntoBackupVault"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organization_id]
    }
  }
}

resource "aws_backup_vault_notifications" "this" {
  backup_vault_name   = aws_backup_vault.this.name
  sns_topic_arn       = var.sns_topic_arn
  backup_vault_events = var.notification_events
}

###############################################################################
# S3 Backup Bucket
###############################################################################

resource "aws_s3_bucket" "backup" {
  bucket = "${var.name}-${data.aws_region.current.name}"

  tags = merge(
    var.tags,
    {
      Name        = "${var.name}-${data.aws_region.current.name}"
      description = "Stores disaster recovery backups"
    },
  )

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "delete-after-${var.backup_retention_days}-days"
    status = "Enabled"

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 5
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id

  policy = data.aws_iam_policy_document.bucket_policy.json
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid    = "AllowProductionOUReadAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "s3:ListBucket",
      "s3:Get*",
    ]

    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgPaths"
      values   = var.bucket_read_org_paths
    }
  }
}

###############################################################################
# Cross-Account Backup IAM Role
###############################################################################

resource "aws_iam_role" "cross_account_backup" {
  name = var.cross_account_role_name
  path = "/"

  assume_role_policy = data.aws_iam_policy_document.backup_role_trust.json

  tags = merge(
    var.tags,
    {
      Name = var.cross_account_role_name
    },
  )
}

data "aws_iam_policy_document" "backup_role_trust" {
  statement {
    sid     = "AllowSourceAccountAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for id in var.backup_source_account_ids : "arn:aws:iam::${id}:root"]
    }
  }
}

# Policy: KMS key access for generating data keys
resource "aws_iam_role_policy" "kms_access" {
  name   = "allow-kms-key-access"
  role   = aws_iam_role.cross_account_backup.id
  policy = data.aws_iam_policy_document.kms_access.json
}

data "aws_iam_policy_document" "kms_access" {
  statement {
    sid       = "AllowKmsGenerateDataKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [aws_kms_key.backup.arn]
  }
}

# Policy: S3 bucket write access for backups
resource "aws_iam_role_policy" "s3_access" {
  name   = "allow-s3-bucket-access"
  role   = aws_iam_role.cross_account_backup.id
  policy = data.aws_iam_policy_document.s3_access.json
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid       = "AllowS3PutObject"
    effect    = "Allow"
    actions   = ["s3:PutObject*"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
  }
}

# Policy: EC2 AMI copy permissions
resource "aws_iam_role_policy" "ec2_copy_image" {
  name   = "ec2-copyImage-permissions"
  role   = aws_iam_role.cross_account_backup.id
  policy = data.aws_iam_policy_document.ec2_copy_image.json
}

data "aws_iam_policy_document" "ec2_copy_image" {
  statement {
    sid    = "AllowEc2ImageOperations"
    effect = "Allow"

    actions = [
      "ec2:DescribeImages",
      "ec2:CopyImage",
      "ec2:CreateTags",
      "ec2:DeregisterImage",
      "ec2:DeleteSnapshot",
      "ec2:ModifyImageAttribute",
      "ec2:ModifySnapshotAttribute",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowKmsForImageEncryption"
    effect = "Allow"

    actions = [
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:CreateGrant",
      "kms:GenerateDataKey*",
    ]

    resources = ["*"]
  }
}

# Policy: ECR image copy permissions
resource "aws_iam_role_policy" "ecr_copy_image" {
  name   = "ecr-copyImage-permissions"
  role   = aws_iam_role.cross_account_backup.id
  policy = data.aws_iam_policy_document.ecr_copy_image.json
}

data "aws_iam_policy_document" "ecr_copy_image" {
  statement {
    sid    = "AllowEcrImageOperations"
    effect = "Allow"

    actions = [
      "ecr:DescribeRepositories",
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeImages",
      "ecr:BatchDeleteImage",
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]

    resources = ["*"]
  }
}
