################################################################################
# CDK Bootstrap Resources
#
# Modern Terraform implementation of AWS CDK bootstrap (v21).
# Based on the official CDK bootstrap template but implemented as
# native Terraform resources following current best practices:
#
#   - S3 staging bucket for file assets (KMS encrypted, versioned)
#   - ECR repository for container image assets
#   - IAM roles for file publishing, image publishing, lookups, deployment, and CFN execution
#   - SSM parameter for bootstrap version tracking
#   - KMS key for asset encryption (optional)
#
# Key improvements over the original CloudFormation template:
#   - Native Terraform lifecycle management
#   - Proper resource tagging
#   - KMS key rotation enabled by default
#   - Configurable bootstrap version (default v21)
#   - Explicit resource dependencies
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition
  qualifier  = var.qualifier

  create_new_key  = var.file_assets_bucket_kms_key_id == ""
  use_managed_key = var.file_assets_bucket_kms_key_id == "AWS_MANAGED_KEY"

  bucket_name = var.file_assets_bucket_name != "" ? var.file_assets_bucket_name : "cdk-${local.qualifier}-assets-${local.account_id}-${local.region}"
  ecr_name    = var.container_assets_repository_name != "" ? var.container_assets_repository_name : "cdk-${local.qualifier}-container-assets-${local.account_id}-${local.region}"

  # Build trust principals: always include self account, plus trusted accounts
  self_trust = [local.account_id]
  all_trusted = concat(
    local.self_trust,
    var.trusted_accounts
  )
  all_trusted_for_lookup = concat(
    local.self_trust,
    var.trusted_accounts,
    var.trusted_accounts_for_lookup
  )

  cfn_exec_policies = length(var.cloudformation_execution_policies) > 0 ? var.cloudformation_execution_policies : (
    length(var.trusted_accounts) > 0 ? [] : ["arn:${local.partition}:iam::aws:policy/AdministratorAccess"]
  )

  common_tags = merge(var.tags, {
    "aws-cdk:bootstrap-qualifier" = local.qualifier
  })
}

################################################################################
# KMS Key for File Assets Encryption
################################################################################

resource "aws_kms_key" "assets" {
  count = local.create_new_key ? 1 : 0

  description             = "CDK bootstrap assets encryption key (${local.qualifier})"
  enable_key_rotation     = var.enable_kms_key_rotation
  deletion_window_in_days = var.kms_key_deletion_window

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KeyAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
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
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:GenerateDataKey",
          "kms:TagResource",
          "kms:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "KeyUsageViaS3"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "s3.${local.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "FilePublishingRoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.file_publishing.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "assets" {
  count = local.create_new_key ? 1 : 0

  name          = "alias/cdk-${local.qualifier}-assets-key"
  target_key_id = aws_kms_key.assets[0].key_id
}

################################################################################
# S3 Staging Bucket for File Assets
################################################################################

resource "aws_s3_bucket" "staging" {
  bucket = local.bucket_name

  tags = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "staging" {
  bucket = aws_s3_bucket.staging.id

  versioning_configuration {
    status = var.enable_bucket_versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.create_new_key ? aws_kms_key.assets[0].arn : (local.use_managed_key ? null : var.file_assets_bucket_kms_key_id)
    }
  }
}

resource "aws_s3_bucket_public_access_block" "staging" {
  count = var.enable_public_access_block ? 1 : 0

  bucket = aws_s3_bucket.staging.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "staging" {
  bucket = aws_s3_bucket.staging.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "AccessControl"
    Statement = [
      {
        Sid       = "AllowSSLRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.staging.arn,
          "${aws_s3_bucket.staging.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}

################################################################################
# ECR Repository for Container Assets
################################################################################

resource "aws_ecr_repository" "assets" {
  name = local.ecr_name

  image_scanning_configuration {
    scan_on_push = var.enable_ecr_image_scanning
  }

  image_tag_mutability = "MUTABLE"

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "assets" {
  repository = aws_ecr_repository.assets.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images older than 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

################################################################################
# IAM Roles
################################################################################

# File Publishing Role
resource "aws_iam_role" "file_publishing" {
  name = "cdk-${local.qualifier}-file-publishing-role-${local.account_id}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for account_id in local.all_trusted : {
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = account_id }
    }]
  })

  tags = merge(local.common_tags, {
    "aws-cdk:bootstrap-role" = "file-publishing"
  })
}

resource "aws_iam_role_policy" "file_publishing" {
  name = "cdk-${local.qualifier}-file-publishing-role-default-policy-${local.account_id}-${local.region}"
  role = aws_iam_role.file_publishing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject*",
          "s3:GetBucket*",
          "s3:GetEncryptionConfiguration",
          "s3:List*",
          "s3:DeleteObject*",
          "s3:PutObject*",
          "s3:Abort*",
        ]
        Resource = [
          aws_s3_bucket.staging.arn,
          "${aws_s3_bucket.staging.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
        ]
        Resource = local.create_new_key ? aws_kms_key.assets[0].arn : "arn:${local.partition}:kms:${local.region}:${local.account_id}:key/${var.file_assets_bucket_kms_key_id}"
      },
    ]
  })
}

# Image Publishing Role
resource "aws_iam_role" "image_publishing" {
  name = "cdk-${local.qualifier}-image-publishing-role-${local.account_id}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for account_id in local.all_trusted : {
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = account_id }
    }]
  })

  tags = merge(local.common_tags, {
    "aws-cdk:bootstrap-role" = "image-publishing"
  })
}

resource "aws_iam_role_policy" "image_publishing" {
  name = "cdk-${local.qualifier}-image-publishing-role-default-policy-${local.account_id}-${local.region}"
  role = aws_iam_role.image_publishing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchCheckLayerAvailability",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.assets.arn
      },
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
    ]
  })
}

# Lookup Role
resource "aws_iam_role" "lookup" {
  name = "cdk-${local.qualifier}-lookup-role-${local.account_id}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for account_id in local.all_trusted_for_lookup : {
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = account_id }
    }]
  })

  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess",
  ]

  inline_policy {
    name = "LookupRolePolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "DontReadSecrets"
          Effect   = "Deny"
          Action   = "kms:Decrypt"
          Resource = "*"
        },
      ]
    })
  }

  tags = merge(local.common_tags, {
    "aws-cdk:bootstrap-role" = "lookup"
  })
}

# Deployment Action Role
resource "aws_iam_role" "deploy" {
  name = "cdk-${local.qualifier}-deploy-role-${local.account_id}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for account_id in local.all_trusted : {
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = account_id }
    }]
  })

  inline_policy {
    name = "default"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid    = "CloudFormationPermissions"
          Effect = "Allow"
          Action = [
            "cloudformation:CreateChangeSet",
            "cloudformation:DeleteChangeSet",
            "cloudformation:DescribeChangeSet",
            "cloudformation:DescribeStacks",
            "cloudformation:ExecuteChangeSet",
            "cloudformation:CreateStack",
            "cloudformation:UpdateStack",
          ]
          Resource = "*"
        },
        {
          Sid    = "PipelineCrossAccountArtifactsBucket"
          Effect = "Allow"
          Action = [
            "s3:GetObject*",
            "s3:GetBucket*",
            "s3:List*",
            "s3:Abort*",
            "s3:DeleteObject*",
            "s3:PutObject*",
          ]
          Resource  = "*"
          Condition = {
            StringNotEquals = {
              "s3:ResourceAccount" = local.account_id
            }
          }
        },
        {
          Sid    = "PipelineCrossAccountArtifactsKey"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey",
            "kms:Encrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
          ]
          Resource  = "*"
          Condition = {
            StringEquals = {
              "kms:ViaService" = "s3.${local.region}.amazonaws.com"
            }
          }
        },
        {
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = aws_iam_role.cfn_exec.arn
        },
        {
          Sid    = "CliPermissions"
          Effect = "Allow"
          Action = [
            "cloudformation:DescribeStackEvents",
            "cloudformation:GetTemplate",
            "cloudformation:DeleteStack",
            "cloudformation:UpdateTerminationProtection",
            "sts:GetCallerIdentity",
          ]
          Resource = "*"
        },
        {
          Sid    = "CliStagingBucket"
          Effect = "Allow"
          Action = [
            "s3:GetObject*",
            "s3:GetBucket*",
            "s3:List*",
          ]
          Resource = [
            aws_s3_bucket.staging.arn,
            "${aws_s3_bucket.staging.arn}/*",
          ]
        },
        {
          Sid      = "ReadVersion"
          Effect   = "Allow"
          Action   = "ssm:GetParameter"
          Resource = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${aws_ssm_parameter.bootstrap_version.name}"
        },
      ]
    })
  }

  tags = merge(local.common_tags, {
    "aws-cdk:bootstrap-role" = "deploy"
  })
}

# CloudFormation Execution Role
resource "aws_iam_role" "cfn_exec" {
  name = "cdk-${local.qualifier}-cfn-exec-role-${local.account_id}-${local.region}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "cloudformation.amazonaws.com" }
      },
    ]
  })

  managed_policy_arns = local.cfn_exec_policies

  tags = local.common_tags
}

################################################################################
# SSM Parameter for Bootstrap Version
################################################################################

resource "aws_ssm_parameter" "bootstrap_version" {
  name  = "/cdk-bootstrap/${local.qualifier}/version"
  type  = "String"
  value = var.bootstrap_version

  tags = local.common_tags
}
