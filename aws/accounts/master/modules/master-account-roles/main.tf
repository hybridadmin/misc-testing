###############################################################################
# Master Account Roles
# Backup services role and Route53 access role for the management account.
###############################################################################

# ------------------------------------------------------------------------------
# Backup Access Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "backup_access" {
  name = "ORGRoleForBackupServices"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = var.backup_services_account_id
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "backup_route53_read" {
  name = "route53-read-permissions"
  role = aws_iam_role.backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "backup_ec2" {
  name = "manage-ec2-resources"
  role = aws_iam_role.backup_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeImages",
        "ec2:DeregisterImage",
        "ec2:DescribeSnapshots",
        "ec2:DeleteSnapshot",
        "ec2:DescribeVolumes",
        "ec2:DescribeInstances",
        "ec2:CreateImage",
        "ec2:CreateTags"
      ]
      Resource = "*"
    }]
  })
}

# ------------------------------------------------------------------------------
# Route53 Access Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "route53_access" {
  name = "Route53AccessRole"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = var.route53_trusted_account_ids
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "route53_read" {
  name = "route53-read-permissions"
  role = aws_iam_role.route53_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "route53:ListHostedZones",
        "route53:GetChange"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "route53_update" {
  name = "route53-update-permissions"
  role = aws_iam_role.route53_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "route53:GetHostedZone",
        "route53:ChangeResourceRecordSets"
      ]
      Resource = [for zone_id in var.hosted_zone_ids : "arn:aws:route53:::hostedzone/${zone_id}"]
    }]
  })
}
