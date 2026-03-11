###############################################################################
# Security Alarms
# CloudTrail with CloudWatch Logs, CIS metric filters and alarms.
# Ported from CloudFormation: security-alarms.yml
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_upper}-${var.environment_upper}"
  name_lower  = "${var.project_lower}-${var.environment_lower}"
  sns_topic_arn = aws_sns_topic.security.arn
}

# ------------------------------------------------------------------------------
# CloudWatch Log Group for CloudTrail
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "${var.stack_name}-CloudTrailLogs"
  retention_in_days = 90
  tags              = var.tags
}

# ------------------------------------------------------------------------------
# IAM Role for CloudTrail -> CloudWatch Logs
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cloudtrail" {
  name = "${var.stack_name}-CloudTrailRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name = "write-log-group-policy"
  role = aws_iam_role.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ------------------------------------------------------------------------------
# CloudTrail S3 Bucket
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${local.name_lower}-cloudtraillogs-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    description = "Cloudtrail logs for security hub related alarms"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = "arn:aws:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/s3"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CloudTrail
# ------------------------------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = var.stack_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = var.tags
}

# ------------------------------------------------------------------------------
# SNS Topic for Security Alerts
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "security" {
  name         = "${local.name_prefix}-events-security"
  display_name = "${local.name_prefix}-events-security"
  tags         = var.tags
}

resource "aws_sns_topic_subscription" "security_lambda" {
  count     = var.sns_lambda_arn != "" ? 1 : 0
  topic_arn = aws_sns_topic.security.arn
  protocol  = "lambda"
  endpoint  = var.sns_lambda_arn
}

# ==============================================================================
# CIS 3.1 - Unauthorized API Calls
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "unauthorized_attempts" {
  name           = "UnauthorizedAttemptCount"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.errorCode=\"*UnauthorizedOperation\") || ($.errorCode=\"AccessDenied*\")}"

  metric_transformation {
    name      = "UnauthorizedAttemptCount"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_attempts" {
  alarm_name          = "SecurityAlarm Unauthorized Activity Attempt"
  alarm_description   = "Multiple unauthorized actions or logins attempted"
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "UnauthorizedAttemptCount"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.2 - Console Sign-in Without MFA (External IdP / SSO)
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "console_signin_without_mfa_sso" {
  count          = var.external_idp ? 1 : 0
  name           = "ConsoleSigninWithoutMFAWithoutSSO"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed !=\"Yes\") && ($.userIdentity.arn != \"*AWSReservedSSO*\")}"

  metric_transformation {
    name      = "ConsoleSigninWithoutMFAWithoutSSO"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "console_signin_without_mfa_sso" {
  count               = var.external_idp ? 1 : 0
  alarm_name          = "SecurityAlarm Console Signin Without MFA exluding SSO"
  alarm_description   = "Console signin without MFA, excluding external SSO IdP domains"
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "ConsoleSigninWithoutMFAWithoutSSO"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 1.1 / 3.3 - Root Account Activity
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "root_activity" {
  name           = "RootUserEventCount"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{$.userIdentity.type=\"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType !=\"AwsServiceEvent\"}"

  metric_transformation {
    name      = "RootUserEventCount"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_activity" {
  alarm_name          = "SecurityAlarm IAM Root Activity"
  alarm_description   = "Root user activity detected"
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "RootUserEventCount"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.4 - IAM Policy Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "IAMPolicyChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=DeleteGroupPolicy) || ($.eventName=DeleteRolePolicy) || ($.eventName=DeleteUserPolicy) || ($.eventName=PutGroupPolicy) || ($.eventName=PutRolePolicy) || ($.eventName=PutUserPolicy) || ($.eventName=CreatePolicy) || ($.eventName=DeletePolicy) || ($.eventName=CreatePolicyVersion) || ($.eventName=DeletePolicyVersion) || ($.eventName=AttachRolePolicy) || ($.eventName=DetachRolePolicy) || ($.eventName=AttachUserPolicy) || ($.eventName=DetachUserPolicy) || ($.eventName=AttachGroupPolicy) || ($.eventName=DetachGroupPolicy)}"

  metric_transformation {
    name      = "IAMPolicyChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm IAM Policy Changes"
  alarm_description   = "Alarm for IAM Policy Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "IAMPolicyChanges"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.5 - CloudTrail Configuration Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "cloudtrail_config_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "CloudTrailConfigChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=CreateTrail) || ($.eventName=UpdateTrail) || ($.eventName=DeleteTrail) || ($.eventName=StartLogging) || ($.eventName=StopLogging)}"

  metric_transformation {
    name      = "CloudTrailConfigChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_config_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm CloudTrail Config Changes"
  alarm_description   = "Alarm for CloudTrail Configuration Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "CloudTrailConfigChanges"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.6 - Console Authentication Failures
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "console_login_failures" {
  name           = "ConsoleLoginFailures"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=ConsoleLogin) && ($.errorMessage=\"Failed authentication\")}"

  metric_transformation {
    name      = "ConsoleLoginFailures"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "console_login_failures" {
  alarm_name          = "SecurityAlarm Console Login Failures"
  alarm_description   = "Console login failures over a five-minute period"
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "ConsoleLoginFailures"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.7 - Disabling or Scheduled Deletion of CMKs
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "disable_delete_cmk" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "DisableDeleteCMK"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventSource=kms.amazonaws.com) && (($.eventName=DisableKey) || ($.eventName=ScheduleKeyDeletion))}"

  metric_transformation {
    name      = "DisableDeleteCMK"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "disable_delete_cmk" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm Disable Delete CMK"
  alarm_description   = "Alarm for Disabling or Scheduled Deletion of Customer Created CMKs."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "DisableDeleteCMK"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.8 - S3 Bucket Policy Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "s3_bucket_policy_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "S3BucketPolicyChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventSource=s3.amazonaws.com) && (($.eventName=PutBucketAcl) || ($.eventName=PutBucketPolicy) || ($.eventName=PutBucketCors) || ($.eventName=PutBucketLifecycle) || ($.eventName=PutBucketReplication) || ($.eventName=DeleteBucketPolicy) || ($.eventName=DeleteBucketCors) || ($.eventName=DeleteBucketLifecycle) || ($.eventName=DeleteBucketReplication))}"

  metric_transformation {
    name      = "S3BucketPolicyChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3_bucket_policy_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm S3 Bucket Policy Changes"
  alarm_description   = "Alarm for S3 Bucket Policy Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "S3BucketPolicyChanges"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.9 - AWS Config Configuration Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "aws_config_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "AWSConfigChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventSource=config.amazonaws.com) && (($.eventName=StopConfigurationRecorder) || ($.eventName=DeleteDeliveryChannel) || ($.eventName=PutDeliveryChannel) || ($.eventName=PutConfigurationRecorder))}"

  metric_transformation {
    name      = "AWSConfigChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "aws_config_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm AWS Config Changes."
  alarm_description   = "Alarm for AWS Config Configuration Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "AWSConfigChanges"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.10 - Security Group Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "sec_group_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "SecGroupChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=AuthorizeSecurityGroupIngress) || ($.eventName=AuthorizeSecurityGroupEgress) || ($.eventName=RevokeSecurityGroupIngress) || ($.eventName=RevokeSecurityGroupEgress) || ($.eventName=CreateSecurityGroup) || ($.eventName=DeleteSecurityGroup)}"

  metric_transformation {
    name      = "SecGroupChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "sec_group_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm Security Group Change"
  alarm_description   = "Alarm for Security Group Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "SecGroupChanges"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.11 - NACL Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "nacl_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "VPCNACLChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=CreateNetworkAcl) || ($.eventName=CreateNetworkAclEntry) || ($.eventName=DeleteNetworkAcl) || ($.eventName=DeleteNetworkAclEntry) || ($.eventName=ReplaceNetworkAclEntry) || ($.eventName=ReplaceNetworkAclAssociation)}"

  metric_transformation {
    name      = "VPC NACL Changes"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "nacl_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm VPC NACL Changes"
  alarm_description   = "Alarm for Changes to Network Access Control Lists (NACL)."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "VPC NACL Changes"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.12 - Network Gateway Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "network_gateway_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "VPCNetworkGatewayChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=CreateCustomerGateway) || ($.eventName=DeleteCustomerGateway) || ($.eventName=AttachInternetGateway) || ($.eventName=CreateInternetGateway) || ($.eventName=DeleteInternetGateway) || ($.eventName=DetachInternetGateway)}"

  metric_transformation {
    name      = "VPC Network Gateway Changes"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "network_gateway_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm VPC Network Gateway Changes"
  alarm_description   = "Alarm for Changes to Network Gateways."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "VPC Network Gateway Changes"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.13 - Route Table Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "route_table_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "VPCRouteTableChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=CreateRoute) || ($.eventName=CreateRouteTable) || ($.eventName=ReplaceRoute) || ($.eventName=ReplaceRouteTableAssociation) || ($.eventName=DeleteRouteTable) || ($.eventName=DeleteRoute) || ($.eventName=DisassociateRouteTable)}"

  metric_transformation {
    name      = "VPC Route Table Changes"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "route_table_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm VPC Route Table Changes"
  alarm_description   = "Alarm for Route Table Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "VPC Route Table Changes"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ==============================================================================
# CIS 3.14 - VPC Changes
# ==============================================================================
resource "aws_cloudwatch_log_metric_filter" "vpc_changes" {
  count          = var.security_hub_rules ? 1 : 0
  name           = "VPCChanges"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{($.eventName=CreateVpc) || ($.eventName=DeleteVpc) || ($.eventName=ModifyVpcAttribute) || ($.eventName=AcceptVpcPeeringConnection) || ($.eventName=CreateVpcPeeringConnection) || ($.eventName=DeleteVpcPeeringConnection) || ($.eventName=RejectVpcPeeringConnection) || ($.eventName=AttachClassicLinkVpc) || ($.eventName=DetachClassicLinkVpc) || ($.eventName=DisableVpcClassicLink) || ($.eventName=EnableVpcClassicLink)}"

  metric_transformation {
    name      = "VPC Changes"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "vpc_changes" {
  count               = var.security_hub_rules ? 1 : 0
  alarm_name          = "SecurityAlarm VPC Changes"
  alarm_description   = "Alarm for VPC Changes."
  alarm_actions       = [local.sns_topic_arn]
  metric_name         = "VPC Changes"
  namespace           = "CloudTrailMetrics"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}
