###############################################################################
# Config Rules
# AWS Config rules with SSM automation remediation for tag compliance.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  is_primary_region = data.aws_region.current.name == var.primary_region
  is_not_excluded   = !contains(var.excluded_regions, data.aws_region.current.name)
}

# ------------------------------------------------------------------------------
# IAM Role for SSM Automation (primary region only)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "automation" {
  count = local.is_primary_region ? 1 : 0
  name  = "CustomConfigRulesAutomation"
  path  = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "automation_sns" {
  count = local.is_primary_region ? 1 : 0
  name  = "publish-sns"
  role  = aws_iam_role.automation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = "arn:aws:sns:*:${data.aws_caller_identity.current.account_id}:devops-events-general"
    }]
  })
}

# ------------------------------------------------------------------------------
# SSM Automation Document - SNS Notification for non-compliance
# ------------------------------------------------------------------------------
resource "aws_ssm_document" "sns_notification_remediation" {
  name            = "SNSNotificationRemediationDocument"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Publish SNS Notification for non-compliance"
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "(Required) The ARN of the role that allows Automation to perform the actions on your behalf."
        default     = ""
      }
      TopicArn = {
        type        = "String"
        description = "(Required) The ARN of the SNS topic to publish the notification to."
      }
      Subject = {
        type        = "String"
        description = "(Required) The email subject"
      }
      AccountId = {
        type        = "String"
        description = "(Required) AccountId of the resource's account."
      }
      Region = {
        type        = "String"
        description = "(Required) Region where the resource is located."
      }
      ResourceType = {
        type        = "String"
        description = "(Required) Resource type that is missing the mandatory tag."
      }
      ResourceId = {
        type        = "String"
        description = "(Required) Resource Id."
      }
      NoncomplianceReason = {
        type        = "String"
        description = "(Required) Reason for the notification."
      }
    }
    mainSteps = [{
      name   = "PublishSNSNotification"
      action = "aws:executeAwsApi"
      inputs = {
        Service  = "sns"
        Api      = "Publish"
        TopicArn = "{{TopicArn}}"
        Subject  = "{{Subject}}"
        Message  = "Account {{AccountId}} {{ResourceType}} {{ResourceId}} in {{Region}} {{NoncomplianceReason}}"
      }
    }]
  })

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Config Rule: S3 Mandatory Tags
# ------------------------------------------------------------------------------
resource "aws_config_config_rule" "s3_mandatory_tags" {
  name        = "S3MandatoryTags"
  description = "Checks S3 buckets for mandatory tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  input_parameters = jsonencode({
    tag1Key = var.mandatory_tag_key
  })

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Remediation: S3 Mandatory Tags -> SNS notification
# ------------------------------------------------------------------------------
resource "aws_config_remediation_configuration" "s3_mandatory_tags" {
  count = local.is_not_excluded ? 1 : 0

  config_rule_name = aws_config_config_rule.s3_mandatory_tags.name
  automatic        = true
  target_type      = "SSM_DOCUMENT"
  target_id        = aws_ssm_document.sns_notification_remediation.name
  target_version   = "1"

  maximum_automatic_attempts = 2
  retry_attempt_seconds      = 60

  parameter {
    name           = "AutomationAssumeRole"
    static_value   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/CustomConfigRulesAutomation"
  }

  parameter {
    name           = "TopicArn"
    static_value   = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:devops-events-general"
  }

  parameter {
    name         = "Subject"
    static_value = "Resource Missing Mandatory Tag"
  }

  parameter {
    name         = "AccountId"
    static_value = data.aws_caller_identity.current.account_id
  }

  parameter {
    name         = "Region"
    static_value = data.aws_region.current.name
  }

  parameter {
    name         = "ResourceType"
    static_value = "S3 Bucket"
  }

  parameter {
    name           = "ResourceId"
    resource_value = "RESOURCE_ID"
  }

  parameter {
    name         = "NoncomplianceReason"
    static_value = "is missing mandatory tag '${var.mandatory_tag_key}'"
  }
}
