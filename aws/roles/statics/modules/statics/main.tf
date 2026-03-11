# -----------------------------------------------------------------------------
# Statics Terraform Module
#
# Provisions persistent resources with a lifecycle outside the VPC, including
# SNS topics (critical/general), S3 buckets (project + logs), bucket policies,
# and an AWS App Mesh.
#
# Ported from CloudFormation: roles/statics/files/template.json
#
# Resources created:
#   - SNS Topic for critical application events
#   - SNS Topic for general application events
#   - S3 Project Bucket (KMS encrypted, versioned, public access blocked)
#   - S3 Logs Bucket (AES256 encrypted, lifecycle rules, public access blocked)
#   - S3 Bucket Policy for logs (ELB access logging, VPC flow logs)
#   - AWS App Mesh with ALLOW_ALL egress
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${upper(var.project)}-${upper(var.environment)}"

  # ELB Account IDs per region for access logging bucket policy
  # Reference: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
  elb_account_id_map = {
    "af-south-1"     = "098369216593"
    "ap-northeast-1" = "582318560864"
    "ap-northeast-2" = "600734575887"
    "ap-south-1"     = "718504428378"
    "ap-southeast-1" = "114774131450"
    "ap-southeast-2" = "783225319266"
    "ca-central-1"   = "985666609251"
    "eu-central-1"   = "054676820928"
    "eu-west-1"      = "156460612806"
    "eu-west-2"      = "652711504416"
    "sa-east-1"      = "507241528517"
    "us-east-1"      = "127311923021"
    "us-east-2"      = "033677994240"
    "us-west-1"      = "027434742980"
    "us-west-2"      = "797873946194"
  }

  elb_account_id = lookup(local.elb_account_id_map, data.aws_region.current.name, "")

  common_tags = merge(var.tags, {
    project     = lower(var.project)
    environment = lower(var.environment)
    service     = lower(var.service)
    managed_by  = "terragrunt"
  })
}

# -----------------------------------------------------------------------------
# SNS Topics
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "critical" {
  name = "${local.name_prefix}-events-critical"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "critical_lambda" {
  count = var.sns_to_email_lambda_arn != "" ? 1 : 0

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "lambda"
  endpoint  = var.sns_to_email_lambda_arn
}

resource "aws_lambda_permission" "critical_sns" {
  count = var.sns_to_email_lambda_arn != "" ? 1 : 0

  statement_id  = "AllowSNSCriticalInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.sns_to_email_lambda_arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.critical.arn
}

resource "aws_sns_topic" "general" {
  name = "${local.name_prefix}-events-general"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "general_lambda" {
  count = var.sns_to_email_lambda_arn != "" ? 1 : 0

  topic_arn = aws_sns_topic.general.arn
  protocol  = "lambda"
  endpoint  = var.sns_to_email_lambda_arn
}

resource "aws_lambda_permission" "general_sns" {
  count = var.sns_to_email_lambda_arn != "" ? 1 : 0

  statement_id  = "AllowSNSGeneralInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.sns_to_email_lambda_arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.general.arn
}

# -----------------------------------------------------------------------------
# Project S3 Bucket (KMS encrypted, versioned)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "project" {
  bucket = "${lower(var.project)}-${lower(var.environment)}-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    description = "Project bucket for ${upper(var.project)}"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "project" {
  bucket = aws_s3_bucket.project.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "project" {
  bucket = aws_s3_bucket.project.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = "alias/aws/s3"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "project" {
  bucket = aws_s3_bucket.project.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "project" {
  bucket = aws_s3_bucket.project.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Logs S3 Bucket (AES256 encrypted, lifecycle rules)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  bucket = "${lower(var.project)}-${lower(var.environment)}-logs-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    description = "Logs bucket for ${upper(var.project)}"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "logs-lifecycle"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 5
    }

    expiration {
      days = var.logs_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.logs_expiration_days
    }
  }
}

# -----------------------------------------------------------------------------
# Logs Bucket Policy (ELB access logging + VPC flow logs)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # ELB access logging - only include if region has an ELB account ID
      local.elb_account_id != "" ? [
        {
          Effect = "Allow"
          Principal = {
            AWS = [local.elb_account_id]
          }
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.logs.arn}/alb/AWSLogs/*"
        }
      ] : [],
      [
        {
          Sid    = "AWSLogDeliveryWrite"
          Effect = "Allow"
          Principal = {
            Service = "delivery.logs.amazonaws.com"
          }
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.logs.arn}/VPC-LOGS/*"
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            }
          }
        },
        {
          Sid    = "AWSLogDeliveryCheck"
          Effect = "Allow"
          Principal = {
            Service = "delivery.logs.amazonaws.com"
          }
          Action   = ["s3:GetBucketAcl", "s3:ListBucket"]
          Resource = aws_s3_bucket.logs.arn
          Condition = {
            StringEquals = {
              "aws:SourceAccount" = data.aws_caller_identity.current.account_id
            }
          }
        }
      ]
    )
  })
}

# -----------------------------------------------------------------------------
# AWS App Mesh
# -----------------------------------------------------------------------------

resource "aws_appmesh_mesh" "this" {
  name = local.name_prefix

  spec {
    egress_filter {
      type = "ALLOW_ALL"
    }
  }

  tags = local.common_tags
}
