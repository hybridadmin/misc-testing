output "backup_events_queue_arn" {
  description = "ARN of the backup events SQS queue"
  value       = aws_sqs_queue.backup_events.arn
}

output "backup_events_queue_url" {
  description = "URL of the backup events SQS queue"
  value       = aws_sqs_queue.backup_events.url
}

output "backup_events_dlq_arn" {
  description = "ARN of the backup events dead letter queue"
  value       = aws_sqs_queue.backup_events_dlq.arn
}

output "lambda_backup_route53_arn" {
  description = "ARN of the Route 53 backup Lambda function"
  value       = aws_lambda_function.backup_route53.arn
}

output "lambda_copy_backup_arn" {
  description = "ARN of the copy backup Lambda function"
  value       = aws_lambda_function.copy_backup.arn
}

output "lambda_ec2_image_event_handler_arn" {
  description = "ARN of the EC2 image event handler Lambda function"
  value       = aws_lambda_function.ec2_image_event_handler.arn
}

output "lambda_ec2_image_copy_arn" {
  description = "ARN of the EC2 image copy Lambda function"
  value       = aws_lambda_function.ec2_image_copy.arn
}

output "lambda_ecr_image_event_handler_arn" {
  description = "ARN of the ECR image event handler Lambda function"
  value       = aws_lambda_function.ecr_image_event_handler.arn
}

output "codebuild_project_name" {
  description = "Name of the CodeBuild project for ECR image copies"
  value       = aws_codebuild_project.ecr_copy_image.name
}
