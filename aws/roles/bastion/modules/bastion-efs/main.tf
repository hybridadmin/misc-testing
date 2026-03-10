# -----------------------------------------------------------------------------
# Bastion EFS Terraform Module
#
# Provisions an encrypted EFS filesystem with mount targets across availability
# zones for persistent bastion host storage.
#
# Ported from CloudFormation: efs-template.json
#
# Resources created:
#   - EFS Security Group (NFS port 2049 from VPC CIDR)
#   - KMS Key for EFS encryption
#   - EFS Filesystem (general purpose, encrypted, backup enabled)
#   - EFS Mount Targets (one per AZ, in public subnets)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"

  common_tags = {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = "bastion-efs"
    managed_by  = "terragrunt"
  }
}

# -----------------------------------------------------------------------------
# EFS Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "efs" {
  name_prefix = "${local.name_prefix}-EFS-"
  description = "${local.name_prefix}-BASTIONEFS security group rules."
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
# KMS Key for EFS encryption
# -----------------------------------------------------------------------------

resource "aws_kms_key" "efs" {
  description             = "KMS key for ${local.name_prefix} bastion EFS encryption"
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
  name          = "alias/${lower(var.project)}-${lower(var.environment)}-bastion-efs"
  target_key_id = aws_kms_key.efs.key_id
}

# -----------------------------------------------------------------------------
# EFS Filesystem
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "bastion" {
  performance_mode = "generalPurpose"
  encrypted        = true
  kms_key_id       = aws_kms_key.efs.arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-BASTIONEFS-EFS"
  })
}

resource "aws_efs_backup_policy" "bastion" {
  file_system_id = aws_efs_file_system.bastion.id

  backup_policy {
    status = "ENABLED"
  }
}

# -----------------------------------------------------------------------------
# EFS Mount Targets (one per supplied public subnet)
# -----------------------------------------------------------------------------

resource "aws_efs_mount_target" "bastion" {
  count = length(var.public_subnet_ids)

  file_system_id  = aws_efs_file_system.bastion.id
  subnet_id       = var.public_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}
