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
    Statement = concat(
      [
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
              "kms:ViaService"    = "backup.${data.aws_region.current.id}.amazonaws.com"
              "kms:CallerAccount" = [data.aws_caller_identity.current.account_id, var.backup_account_id]
            }
          }
        },
      ],
      # Cape Town doesn't have organizational support yet
      var.is_cape_town ? [] : [
        {
          Sid    = "AllowBackupAccountServiceRole"
          Effect = "Allow"
          Principal = {
            AWS = "arn:aws:iam::${var.backup_account_id}:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup"
          }
          Action = [
            "kms:CreateGrant",
            "kms:Decrypt",
            "kms:GenerateDataKey*",
          ]
          Resource = "*"
        },
      ]
    )
  })

  tags = var.tags
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${local.name_prefix}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

# -----------------------------------------------------------------------------
# Backup Vault
# -----------------------------------------------------------------------------
resource "aws_backup_vault" "main" {
  name        = "${local.name_prefix}-backup"
  kms_key_arn = aws_kms_key.backup.arn
  tags        = var.tags
}

resource "aws_backup_vault_notifications" "main" {
  backup_vault_name   = aws_backup_vault.main.name
  sns_topic_arn       = "arn:aws:sns:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:${var.sns_topic_name}"
  backup_vault_events = ["COPY_JOB_FAILED"]
}

# Access policy - not applied in Cape Town (no org support)
resource "aws_backup_vault_policy" "main" {
  count             = var.is_cape_town ? 0 : 1
  backup_vault_name = aws_backup_vault.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.backup_account_id}:root"
        }
        Action   = "backup:CopyIntoBackupVault"
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Backup Plan (not created in backup_region / Oregon)
# -----------------------------------------------------------------------------
resource "aws_backup_plan" "daily" {
  count = var.enable_backup_plan ? 1 : 0
  name  = "${local.name_prefix}-backups"

  rule {
    rule_name                = "DailyBackups"
    target_vault_name        = aws_backup_vault.main.name
    schedule                 = "cron(00 00 ? * * *)"
    start_window             = 60
    completion_window        = 180
    enable_continuous_backup = false

    lifecycle {
      delete_after = 14
    }

    copy_action {
      destination_vault_arn = "arn:aws:backup:${var.backup_region}:${data.aws_caller_identity.current.account_id}:backup-vault:${local.name_prefix}-backup"

      lifecycle {
        delete_after = 14
      }
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Backup Selection Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "backup_selection" {
  name = "${local.NAME_PREFIX}-BACKUP-BackupSelectionRole-${data.aws_region.current.id}"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "backup.amazonaws.com" }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup_selection_backup" {
  role       = aws_iam_role.backup_selection.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_selection_s3_backup" {
  role       = aws_iam_role.backup_selection.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}

resource "aws_iam_role_policy_attachment" "backup_selection_s3_restore" {
  role       = aws_iam_role.backup_selection.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"
}

# -----------------------------------------------------------------------------
# Backup Selection (tagged resources: backup=daily)
# -----------------------------------------------------------------------------
resource "aws_backup_selection" "daily" {
  count        = var.enable_backup_plan ? 1 : 0
  name         = "DailyBackupByTag"
  plan_id      = aws_backup_plan.daily[0].id
  iam_role_arn = aws_iam_role.backup_selection.arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "backup"
    value = "daily"
  }
}

# -----------------------------------------------------------------------------
# EventBridge Forwarding Role (only in primary region, e.g., eu-west-1)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "forward_events" {
  count = var.enable_event_forwarding_role ? 1 : 0
  name  = "${local.NAME_PREFIX}-backup-ForwardEvents"
  path  = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "events.amazonaws.com" }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "forward_events" {
  count = var.enable_event_forwarding_role ? 1 : 0
  name  = "allow-event-forwarding"
  role  = aws_iam_role.forward_events[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = var.devops_event_bus_arn
      },
    ]
  })
}

# The role ARN for event forwarding targets - uses the role from primary region
locals {
  forward_events_role_arn = var.enable_event_forwarding_role ? aws_iam_role.forward_events[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.NAME_PREFIX}-backup-ForwardEvents"
}

# -----------------------------------------------------------------------------
# EventBridge Rules to forward events to DevOps account
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "forward_backup_copy" {
  count       = var.enable_backup_copy_event_forwarding ? 1 : 0
  name        = "${local.name_prefix}-backups"
  description = "Forwards AWS Backups CopyEvent Notifications to Devops Account"

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Copy Job State Change"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "forward_backup_copy" {
  count = var.enable_backup_copy_event_forwarding ? 1 : 0
  rule  = aws_cloudwatch_event_rule.forward_backup_copy[0].name
  arn   = var.devops_event_bus_arn

  role_arn  = local.forward_events_role_arn
  target_id = "devops-account-default-bus"
}

resource "aws_cloudwatch_event_rule" "forward_ec2_image" {
  count       = var.enable_ec2_event_forwarding ? 1 : 0
  name        = "${local.name_prefix}-Ec2ImageEvents"
  description = "Forwards EC2 AMI creation and deletion events to Devops Account"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["CopyImage", "DeregisterImage"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "forward_ec2_image" {
  count = var.enable_ec2_event_forwarding ? 1 : 0
  rule  = aws_cloudwatch_event_rule.forward_ec2_image[0].name
  arn   = var.devops_event_bus_arn

  role_arn  = local.forward_events_role_arn
  target_id = "devops-account-default-bus"
}

resource "aws_cloudwatch_event_rule" "forward_ecr_image" {
  count       = var.enable_ecr_event_forwarding ? 1 : 0
  name        = "${local.name_prefix}-ecrImageEvents"
  description = "Forwards ECR image creation and deletion events to Devops Account"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "forward_ecr_image" {
  count = var.enable_ecr_event_forwarding ? 1 : 0
  rule  = aws_cloudwatch_event_rule.forward_ecr_image[0].name
  arn   = var.devops_event_bus_arn

  role_arn  = local.forward_events_role_arn
  target_id = "devops-account-default-bus"
}

# -----------------------------------------------------------------------------
# Cross-Account Backup Role for DevOps account (only in primary region)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "devops_backup_access" {
  count = var.enable_cross_account_role ? 1 : 0
  name  = "${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"
  path  = "/"

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

resource "aws_iam_role_policy" "copy_backup" {
  count = var.enable_cross_account_role ? 1 : 0
  name  = "copyBackup-permissions"
  role  = aws_iam_role.devops_backup_access[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "backup:StartCopyJob"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.NAME_PREFIX}-BACKUP-BackupSelectionRole-*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ec2_image" {
  count = var.enable_cross_account_role ? 1 : 0
  name  = "ec2-copyImage-permissions"
  role  = aws_iam_role.devops_backup_access[0].id

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
  count = var.enable_cross_account_role ? 1 : 0
  name  = "ecr-copyImage-permissions"
  role  = aws_iam_role.devops_backup_access[0].id

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
