locals {
  PROJECT     = upper(var.project)
  ENVIRONMENT = upper(var.environment)
  name_prefix = "${var.project}-${var.environment}"
  NAME_PREFIX = "${local.PROJECT}-${local.ENVIRONMENT}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# KMS Key for Backup Vault encryption
# -----------------------------------------------------------------------------
resource "aws_kms_key" "backup" {
  description         = "AWS Backup Vault CMK"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAccountRootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCrossAccountAdminAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/CrossAccountAdminAccess"
        }
        Action = [
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
        Resource = "*"
      },
      {
        Sid    = "AllowBackupServiceAccess"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService"     = "backup.${data.aws_region.current.id}.amazonaws.com"
            "kms:CallerAccount"  = [data.aws_caller_identity.current.account_id, var.devops_account_id]
          }
        }
      },
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${local.name_prefix}-backups"
  target_key_id = aws_kms_key.backup.key_id
}

# -----------------------------------------------------------------------------
# Backup Vault
# -----------------------------------------------------------------------------
resource "aws_backup_vault" "main" {
  name        = "${local.name_prefix}-backups"
  kms_key_arn = aws_kms_key.backup.arn
  tags        = var.tags
}

resource "aws_backup_vault_notifications" "main" {
  backup_vault_name   = aws_backup_vault.main.name
  sns_topic_arn       = "arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${var.sns_topic_name}"
  backup_vault_events = ["COPY_JOB_FAILED"]
}

resource "aws_backup_vault_policy" "main" {
  backup_vault_name = aws_backup_vault.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "backup:CopyIntoBackupVault"
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.organization_id
          }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 Bucket for Route 53 backups and other file-based backups
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "backup" {
  bucket = "${local.name_prefix}-backups-${data.aws_region.current.id}"

  tags = merge(var.tags, {
    description = "Stores disaster recovery backups"
  })
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
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

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "delete-after-6-months"
    status = "Enabled"

    expiration {
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 5
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:ListBucket",
          "s3:Get*",
        ]
        Resource = [
          aws_s3_bucket.backup.arn,
          "${aws_s3_bucket.backup.arn}/*",
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgPaths" = var.production_ou_path
          }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM Role for DevOps account cross-account access
# -----------------------------------------------------------------------------
resource "aws_iam_role" "devops_backup_access" {
  name = "${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { AWS = "arn:aws:iam::${var.devops_account_id}:root" }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "kms_access" {
  name = "allow-kms-key-access"
  role = aws_iam_role.devops_backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey"]
        Resource = [aws_kms_key.backup.arn]
      },
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "allow-s3-bucket-access"
  role = aws_iam_role.devops_backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject*"]
        Resource = ["${aws_s3_bucket.backup.arn}/*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_image" {
  name = "ec2-copyImage-permissions"
  role = aws_iam_role.devops_backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeImages",
          "ec2:CopyImage",
          "ec2:CreateTags",
          "ec2:DeregisterImage",
          "ec2:DeleteSnapshot",
          "ec2:ModifyImageAttribute",
          "ec2:ModifySnapshotAttribute",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecr_image" {
  name = "ecr-copyImage-permissions"
  role = aws_iam_role.devops_backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
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
        Resource = "*"
      },
    ]
  })
}
