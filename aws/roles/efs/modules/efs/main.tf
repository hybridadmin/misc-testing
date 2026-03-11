# -----------------------------------------------------------------------------
# EFS Terraform Module
#
# Provisions an encrypted EFS filesystem with mount targets across availability
# zones for application persistent storage.
#
# Ported from CloudFormation: roles/efs/files/template.json
#
# Resources created:
#   - EFS Security Group (NFS port 2049 from VPC CIDR)
#   - KMS Key + Alias for EFS encryption at rest
#   - EFS Filesystem (general purpose, encrypted, backup enabled)
#   - EFS Mount Targets (one per private subnet / AZ)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"

  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })
}

# -----------------------------------------------------------------------------
# EFS Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "efs" {
  name_prefix = "${local.name_prefix}-EFS-"
  description = "${local.name_prefix}-EFS security group rules."
  vpc_id      = var.vpc_id

  ingress {
    description = "NFS from local VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-EFS-security-group"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# KMS Key for EFS encryption at rest
# -----------------------------------------------------------------------------

resource "aws_kms_key" "efs" {
  description             = "KMS key for ${local.name_prefix} EFS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-default-1"
    Statement = [
      {
        Sid    = "Allow administration of the key"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "efs" {
  name          = "alias/${lower(var.project)}-${lower(var.environment)}-efs"
  target_key_id = aws_kms_key.efs.key_id
}

# -----------------------------------------------------------------------------
# EFS Filesystem
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "this" {
  performance_mode = "generalPurpose"
  encrypted        = true
  kms_key_id       = aws_kms_key.efs.arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-EFS"
  })
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = "ENABLED"
  }
}

# -----------------------------------------------------------------------------
# EFS Mount Targets (one per supplied private subnet)
#
# The original CloudFormation template created mount targets in private subnets
# conditionally (2 or 3 depending on AZ count). Using count over the subnet
# list handles any number of AZs automatically.
# -----------------------------------------------------------------------------

resource "aws_efs_mount_target" "this" {
  count = length(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}
