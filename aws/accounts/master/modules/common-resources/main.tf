###############################################################################
# Common Resources
# Deployment S3 bucket and SNS notification topics per account/region.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ------------------------------------------------------------------------------
# Deployment S3 Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "deployment" {
  bucket = "deployment-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"

  tags = merge(var.tags, {
    description = "Used by serverless deployments to upload lambda packages"
  })
}

resource "aws_s3_bucket_public_access_block" "deployment" {
  bucket = aws_s3_bucket.deployment.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "deployment" {
  bucket = aws_s3_bucket.deployment.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = "arn:aws:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/s3"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "deployment" {
  bucket = aws_s3_bucket.deployment.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "deployment" {
  bucket = aws_s3_bucket.deployment.id

  rule {
    id     = "delete-objects-after-30-days"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

# ------------------------------------------------------------------------------
# SNS Topics
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "critical" {
  name = "devops-events-critical"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "critical_email" {
  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = var.critical_notifications_email
}

resource "aws_sns_topic" "general" {
  name = "devops-events-general"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "general_email" {
  topic_arn = aws_sns_topic.general.arn
  protocol  = "email"
  endpoint  = var.general_notifications_email
}
