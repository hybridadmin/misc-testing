locals {
  PROJECT     = upper(var.project)
  ENVIRONMENT = upper(var.environment)
  name_prefix = "${var.project}-${var.environment}"
  NAME_PREFIX = "${local.PROJECT}-${local.ENVIRONMENT}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# SQS Queues
# =============================================================================

# Dead Letter Queue for backup events
resource "aws_sqs_queue" "backup_events_dlq" {
  name                      = "${local.NAME_PREFIX}-backupEventsDLQ"
  message_retention_seconds = 1209600 # 14 days

  tags = var.tags
}

# Main backup events queue
resource "aws_sqs_queue" "backup_events" {
  name                       = "${local.NAME_PREFIX}-backupEvents"
  visibility_timeout_seconds = 300 # 5 minutes

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.backup_events_dlq.arn
    maxReceiveCount     = 10
  })

  tags = var.tags
}

# =============================================================================
# CloudWatch Alarms
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.NAME_PREFIX}-backupEventsDLQ-MessagesVisible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Alarm when backup events DLQ has visible messages"
  alarm_actions       = [var.general_notification_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.backup_events_dlq.name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unprocessed_events" {
  alarm_name          = "${local.NAME_PREFIX}-backupEvents-OldestMessage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 3600
  alarm_description   = "Alarm when backup events queue has messages older than 1 hour"
  alarm_actions       = [var.general_notification_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.backup_events.name
  }

  tags = var.tags
}

# =============================================================================
# IAM Roles for Lambda functions
# =============================================================================

# Shared assume role policy for all Lambda functions
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- backupRoute53 Lambda Role ---
resource "aws_iam_role" "backup_route53" {
  name               = "${local.NAME_PREFIX}-backupRoute53-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "backup_route53_basic" {
  role       = aws_iam_role.backup_route53.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "backup_route53" {
  name = "backup-route53-policy"
  role = aws_iam_role.backup_route53.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          var.general_notification_topic_arn,
          var.critical_notification_topic_arn,
        ]
      },
      {
        Effect = "Allow"
        Action = ["sts:AssumeRole"]
        Resource = [
          var.route53_backup_role_arn,
          "arn:aws:iam::*:role/ORGRoleForBackupServices",
        ]
      },
    ]
  })
}

# --- copyBackup Lambda Role ---
resource "aws_iam_role" "copy_backup" {
  name               = "${local.NAME_PREFIX}-copyBackup-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "copy_backup_basic" {
  role       = aws_iam_role.copy_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "copy_backup" {
  name = "copy-backup-policy"
  role = aws_iam_role.copy_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          var.general_notification_topic_arn,
          var.critical_notification_topic_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::*:role/${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"]
      },
    ]
  })
}

# --- ec2ImageEventHandler Lambda Role ---
resource "aws_iam_role" "ec2_image_event_handler" {
  name               = "${local.NAME_PREFIX}-ec2ImageEventHandler-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ec2_image_event_handler_basic" {
  role       = aws_iam_role.ec2_image_event_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ec2_image_event_handler" {
  name = "ec2-image-event-handler-policy"
  role = aws_iam_role.ec2_image_event_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          var.general_notification_topic_arn,
          var.critical_notification_topic_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::*:role/${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.backup_events.arn]
      },
    ]
  })
}

# --- ec2ImageCopy Lambda Role ---
resource "aws_iam_role" "ec2_image_copy" {
  name               = "${local.NAME_PREFIX}-ec2ImageCopy-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ec2_image_copy_basic" {
  role       = aws_iam_role.ec2_image_copy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ec2_image_copy" {
  name = "ec2-image-copy-policy"
  role = aws_iam_role.ec2_image_copy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          var.general_notification_topic_arn,
          var.critical_notification_topic_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::*:role/${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.backup_events.arn]
      },
      {
        # Required for SQS event source mapping
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = [aws_sqs_queue.backup_events.arn]
      },
    ]
  })
}

# --- ecrImageEventHandler Lambda Role ---
resource "aws_iam_role" "ecr_image_event_handler" {
  name               = "${local.NAME_PREFIX}-ecrImageEventHandler-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ecr_image_event_handler_basic" {
  role       = aws_iam_role.ecr_image_event_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ecr_image_event_handler" {
  name = "ecr-image-event-handler-policy"
  role = aws_iam_role.ecr_image_event_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [
          var.general_notification_topic_arn,
          var.critical_notification_topic_arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild"]
        Resource = [aws_codebuild_project.ecr_copy_image.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::*:role/${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"]
      },
    ]
  })
}

# =============================================================================
# Lambda Functions
# =============================================================================

# --- backupRoute53 ---
resource "aws_lambda_function" "backup_route53" {
  function_name = "${local.NAME_PREFIX}-backupRoute53"
  role          = aws_iam_role.backup_route53.arn
  handler       = "src/backupRoute53.handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  filename      = var.lambda_zip_path

  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      project                   = var.project
      environment               = var.environment
      generalNotificationTopic  = var.general_notification_topic_arn
      criticalNotificationTopic = var.critical_notification_topic_arn
      backupAccount             = var.backup_account_id
      backupRegion              = var.backup_region
      config                    = jsonencode(var.route53_config)
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "backup_route53" {
  name              = "/aws/lambda/${aws_lambda_function.backup_route53.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "backup_route53_schedule" {
  name                = "${local.NAME_PREFIX}-backupRoute53-schedule"
  description         = "Triggers Route 53 backup daily at midnight UTC"
  schedule_expression = "cron(00 00 * * ? *)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "backup_route53" {
  rule = aws_cloudwatch_event_rule.backup_route53_schedule.name
  arn  = aws_lambda_function.backup_route53.arn
}

resource "aws_lambda_permission" "backup_route53_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_route53.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_route53_schedule.arn
}

# --- copyBackup ---
resource "aws_lambda_function" "copy_backup" {
  function_name = "${local.NAME_PREFIX}-copyBackup"
  role          = aws_iam_role.copy_backup.arn
  handler       = "src/copyBackup.handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  filename      = var.lambda_zip_path

  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      project                   = var.project
      environment               = var.environment
      generalNotificationTopic  = var.general_notification_topic_arn
      criticalNotificationTopic = var.critical_notification_topic_arn
      backupAccount             = var.backup_account_id
      backupRegion              = var.backup_region
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "copy_backup" {
  name              = "/aws/lambda/${aws_lambda_function.copy_backup.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "copy_backup" {
  name        = "${local.NAME_PREFIX}-copyBackup-event"
  description = "Triggers on AWS Backup Copy Job State Change"

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Copy Job State Change"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "copy_backup" {
  rule = aws_cloudwatch_event_rule.copy_backup.name
  arn  = aws_lambda_function.copy_backup.arn
}

resource "aws_lambda_permission" "copy_backup_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.copy_backup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.copy_backup.arn
}

# --- ec2ImageEventHandler ---
resource "aws_lambda_function" "ec2_image_event_handler" {
  function_name = "${local.NAME_PREFIX}-backup-ec2ImageEventHandler"
  role          = aws_iam_role.ec2_image_event_handler.arn
  handler       = "src/ec2ImageEventHandler.handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  filename      = var.lambda_zip_path

  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      project                   = var.project
      environment               = var.environment
      generalNotificationTopic  = var.general_notification_topic_arn
      criticalNotificationTopic = var.critical_notification_topic_arn
      backupAccount             = var.backup_account_id
      backupRegion              = var.backup_region
      backupEventsQueueUrl      = aws_sqs_queue.backup_events.url
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "ec2_image_event_handler" {
  name              = "/aws/lambda/${aws_lambda_function.ec2_image_event_handler.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "ec2_image_event" {
  name        = "${local.NAME_PREFIX}-ec2ImageEvent"
  description = "Triggers on EC2 CopyImage and DeregisterImage CloudTrail events"

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

resource "aws_cloudwatch_event_target" "ec2_image_event" {
  rule = aws_cloudwatch_event_rule.ec2_image_event.name
  arn  = aws_lambda_function.ec2_image_event_handler.arn
}

resource "aws_lambda_permission" "ec2_image_event_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_image_event_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_image_event.arn
}

# --- ec2ImageCopy ---
resource "aws_lambda_function" "ec2_image_copy" {
  function_name = "${local.NAME_PREFIX}-backup-ec2ImageCopy"
  role          = aws_iam_role.ec2_image_copy.arn
  handler       = "src/ec2ImageCopy.handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  filename      = var.lambda_zip_path

  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      project                   = var.project
      environment               = var.environment
      generalNotificationTopic  = var.general_notification_topic_arn
      criticalNotificationTopic = var.critical_notification_topic_arn
      backupAccount             = var.backup_account_id
      backupRegion              = var.backup_region
      backupEventsQueueUrl      = aws_sqs_queue.backup_events.url
      organizationArn           = var.organization_arn
      amiEncryptionKmsKeyArn    = var.ami_encryption_kms_key_arn
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "ec2_image_copy" {
  name              = "/aws/lambda/${aws_lambda_function.ec2_image_copy.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

# SQS Event Source Mapping for ec2ImageCopy
resource "aws_lambda_event_source_mapping" "ec2_image_copy_sqs" {
  event_source_arn = aws_sqs_queue.backup_events.arn
  function_name    = aws_lambda_function.ec2_image_copy.arn
  enabled          = true
}

# --- ecrImageEventHandler ---
resource "aws_lambda_function" "ecr_image_event_handler" {
  function_name = "${local.NAME_PREFIX}-backup-ecrImageEventHandler"
  role          = aws_iam_role.ecr_image_event_handler.arn
  handler       = "src/ecrImageEventHandler.handler"
  runtime       = var.lambda_runtime
  timeout       = 30
  filename      = var.lambda_zip_path

  source_code_hash = filebase64sha256(var.lambda_zip_path)

  environment {
    variables = {
      project                   = var.project
      environment               = var.environment
      generalNotificationTopic  = var.general_notification_topic_arn
      criticalNotificationTopic = var.critical_notification_topic_arn
      backupAccount             = var.backup_account_id
      backupRegion              = var.backup_region
      copyImageProject          = aws_codebuild_project.ecr_copy_image.name
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "ecr_image_event_handler" {
  name              = "/aws/lambda/${aws_lambda_function.ecr_image_event_handler.function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "ecr_image_event" {
  name        = "${local.NAME_PREFIX}-ecrImageEvent"
  description = "Triggers on ECR Image Action events"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecr_image_event" {
  rule = aws_cloudwatch_event_rule.ecr_image_event.name
  arn  = aws_lambda_function.ecr_image_event_handler.arn
}

resource "aws_lambda_permission" "ecr_image_event_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ecr_image_event_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecr_image_event.arn
}

# =============================================================================
# CodeBuild Project for ECR Image Copy
# =============================================================================

resource "aws_iam_role" "codebuild" {
  name = "${local.name_prefix}-backup-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "codebuild.amazonaws.com" }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "codebuild_base" {
  name = "codebuild-base-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = ["arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.NAME_PREFIX}-backup-ecrImageCopy*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_cross_account" {
  name = "assumeCrossAccountRole"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [var.general_notification_topic_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = ["arn:aws:iam::*:role/${local.NAME_PREFIX}-BACKUP-CrossAccountBackupRole"]
      },
    ]
  })
}

resource "aws_codebuild_project" "ecr_copy_image" {
  name         = "${local.NAME_PREFIX}-backup-ecrImageCopy"
  build_timeout = 15

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "PROJECT"
      value = local.PROJECT
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = local.ENVIRONMENT
    }
    environment_variable {
      name  = "GENERAL_NOTIFICATION_TOPIC"
      value = var.general_notification_topic_arn
    }
    environment_variable {
      name  = "BACKUP_ACCOUNT"
      value = var.backup_account_id
    }
    environment_variable {
      name  = "BACKUP_REGION"
      value = var.backup_region
    }
  }

  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "NO_SOURCE"
    buildspec = yamlencode({
      version = "0.2"
      phases = {
        build = {
          commands = [
            "credentials=$(aws sts assume-role --region $${SRC_REGION} --role-arn arn:aws:iam::$${SRC_ACCOUNT}:role/$${PROJECT}-$${ENVIRONMENT}-BACKUP-CrossAccountBackupRole --role-session-name admin-backup-copy | jq '.Credentials')",
            "export AWS_ACCESS_KEY_ID=$(jq -r '.AccessKeyId' <<< $${credentials})",
            "export AWS_SECRET_ACCESS_KEY=$(jq -r '.SecretAccessKey' <<< $${credentials})",
            "export AWS_SESSION_TOKEN=$(jq -r '.SessionToken' <<< $${credentials})",
            "aws ecr get-login-password --region $${SRC_REGION} | docker login --username AWS --password-stdin $${SRC_ACCOUNT}.dkr.ecr.$${SRC_REGION}.amazonaws.com",
            "docker pull $${SRC_ACCOUNT}.dkr.ecr.$${SRC_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG}",
            "docker tag $${SRC_ACCOUNT}.dkr.ecr.$${SRC_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG} $${SRC_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG}",
            "aws ecr get-login-password --region $${BACKUP_REGION} | docker login --username AWS --password-stdin $${SRC_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com",
            "docker push $${SRC_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG}",
            "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN",
            "credentials=$(aws sts assume-role --region $${BACKUP_REGION} --role-arn arn:aws:iam::$${BACKUP_ACCOUNT}:role/$${PROJECT}-$${ENVIRONMENT}-BACKUP-CrossAccountBackupRole --role-session-name admin-backup-copy | jq '.Credentials')",
            "export AWS_ACCESS_KEY_ID=$(jq -r '.AccessKeyId' <<< $${credentials})",
            "export AWS_SECRET_ACCESS_KEY=$(jq -r '.SecretAccessKey' <<< $${credentials})",
            "export AWS_SESSION_TOKEN=$(jq -r '.SessionToken' <<< $${credentials})",
            "docker tag $${SRC_ACCOUNT}.dkr.ecr.$${SRC_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG} $${BACKUP_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG}",
            "aws ecr get-login-password --region $${BACKUP_REGION} | docker login --username AWS --password-stdin $${BACKUP_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com",
            "docker push $${BACKUP_ACCOUNT}.dkr.ecr.$${BACKUP_REGION}.amazonaws.com/$${IMAGE_NAME}:$${IMAGE_TAG}",
          ]
        }
        post_build = {
          commands = [
            "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN",
            "[ $${CODEBUILD_BUILD_SUCCEEDING} -eq 1 ] || aws sns --region $${AWS_REGION} publish --topic-arn $${GENERAL_NOTIFICATION_TOPIC} --message \"CODEBUILD_BUILD_ID: $${CODEBUILD_BUILD_ID}\" --subject \"Backup of ECR Image $${IMAGE_NAME}:$${IMAGE_TAG} Failed\"",
          ]
        }
      }
    })
  }

  tags = var.tags
}
