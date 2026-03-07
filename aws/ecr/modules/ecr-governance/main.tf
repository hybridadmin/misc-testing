# -----------------------------------------------------------------------------
# ECR Governance Terraform Module
#
# Deploys Lambda functions that automatically apply cross-account repository
# policies and lifecycle policies to newly created ECR repositories.
#
# Resources created:
#   - IAM Role for the Lambda functions
#   - CloudWatch Log Groups for Lambda logs (x2)
#   - Lambda Function: Add-Permissions (cross-account ECR access)
#   - Lambda Function: Attach-LifecyclePolicy (image retention)
#   - EventBridge Rule (ECR CreateRepository via CloudTrail)
#   - Lambda Permissions for EventBridge invocation
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  name_prefix                    = "${upper(var.project)}-${upper(var.environment)}-ECR"
  add_permissions_function_name  = "${local.name_prefix}-Add-Permissions"
  attach_policy_function_name    = "${local.name_prefix}-Attach-LifecyclePolicy"
  eventbridge_rule_name          = "${local.name_prefix}-CreateRepository"

  common_tags = merge(
    {
      project     = lower(var.project)
      environment = lower(var.environment)
      service     = lower(var.service)
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# Package Lambda source code
# -----------------------------------------------------------------------------

data "archive_file" "add_permissions" {
  type        = "zip"
  source_file = var.add_permissions_source_path
  output_path = "${path.module}/../../build/AddPermissions-${md5(file(var.add_permissions_source_path))}.zip"
}

data "archive_file" "attach_policy" {
  type        = "zip"
  source_file = var.attach_policy_source_path
  output_path = "${path.module}/../../build/AttachPolicy-${md5(file(var.attach_policy_source_path))}.zip"
}

# -----------------------------------------------------------------------------
# IAM Role (shared by both Lambda functions)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  name = "${local.name_prefix}-Lambda-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.name_prefix}-LambdaLogs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaLogGroupAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.add_permissions.arn}",
          "${aws_cloudwatch_log_group.add_permissions.arn}:log-stream:*",
          "${aws_cloudwatch_log_group.attach_policy.arn}",
          "${aws_cloudwatch_log_group.attach_policy.arn}:log-stream:*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ecr" {
  name = "${local.name_prefix}-LambdaECR"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPolicyManagement"
        Effect = "Allow"
        Action = [
          "ecr:GetLifecyclePolicy",
          "ecr:PutLifecyclePolicy",
          "ecr:SetRepositoryPolicy",
          "ecr:GetRepositoryPolicy",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ssm" {
  name = "${local.name_prefix}-LambdaSSM"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMParameterAccess"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}-${var.environment}-*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "add_permissions" {
  name              = "/aws/lambda/${local.add_permissions_function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "attach_policy" {
  name              = "/aws/lambda/${local.attach_policy_function_name}"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Lambda Function: Add-Permissions (cross-account ECR repository policies)
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "add_permissions" {
  function_name = local.add_permissions_function_name
  description   = "Automatically applies cross-account repository policies to new ECR repositories"
  handler       = "add_permissions.lambda_handler"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  architectures = var.lambda_architectures

  role = aws_iam_role.lambda.arn

  filename         = data.archive_file.add_permissions.output_path
  source_code_hash = data.archive_file.add_permissions.output_base64sha256

  environment {
    variables = {
      APP_PROJECT     = var.project
      APP_ENVIRONMENT = var.environment
      PULL_ACCOUNT_IDS = jsonencode(var.ecr_pull_account_ids)
      PUSH_ACCOUNT_IDS = jsonencode(var.ecr_push_account_ids)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.add_permissions,
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.lambda_ecr,
  ]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Lambda Function: Attach-LifecyclePolicy (image retention)
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "attach_policy" {
  function_name = local.attach_policy_function_name
  description   = "Automatically applies lifecycle policies to new ECR repositories"
  handler       = "attach_policy.lambda_handler"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  architectures = var.lambda_architectures

  role = aws_iam_role.lambda.arn

  filename         = data.archive_file.attach_policy.output_path
  source_code_hash = data.archive_file.attach_policy.output_base64sha256

  environment {
    variables = {
      APP_PROJECT       = var.project
      APP_ENVIRONMENT   = var.environment
      MAX_IMAGE_COUNT   = tostring(var.lifecycle_max_image_count)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.attach_policy,
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.lambda_ecr,
  ]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EventBridge Rule - triggers on ECR CreateRepository via CloudTrail
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ecr_create_repo" {
  name        = local.eventbridge_rule_name
  description = "Triggers ECR governance Lambdas when a new ECR repository is created"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ecr.amazonaws.com"]
      eventName   = ["CreateRepository"]
    }
  })

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# EventBridge Targets
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_target" "add_permissions" {
  rule = aws_cloudwatch_event_rule.ecr_create_repo.name
  arn  = aws_lambda_function.add_permissions.arn
}

resource "aws_cloudwatch_event_target" "attach_policy" {
  count = var.enable_lifecycle_policy ? 1 : 0

  rule = aws_cloudwatch_event_rule.ecr_create_repo.name
  arn  = aws_lambda_function.attach_policy.arn
}

# -----------------------------------------------------------------------------
# Lambda Permissions - allow EventBridge to invoke the functions
# -----------------------------------------------------------------------------

resource "aws_lambda_permission" "eventbridge_add_permissions" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.add_permissions.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecr_create_repo.arn
}

resource "aws_lambda_permission" "eventbridge_attach_policy" {
  count = var.enable_lifecycle_policy ? 1 : 0

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.attach_policy.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ecr_create_repo.arn
}
