# -----------------------------------------------------------------------------
# SNS Topics
# -----------------------------------------------------------------------------

output "sns_topic_critical_arn" {
  description = "ARN of the critical application events SNS topic"
  value       = aws_sns_topic.critical.arn
}

output "sns_topic_critical_name" {
  description = "Name of the critical application events SNS topic"
  value       = aws_sns_topic.critical.name
}

output "sns_topic_general_arn" {
  description = "ARN of the general application events SNS topic"
  value       = aws_sns_topic.general.arn
}

output "sns_topic_general_name" {
  description = "Name of the general application events SNS topic"
  value       = aws_sns_topic.general.name
}

# -----------------------------------------------------------------------------
# S3 Buckets
# -----------------------------------------------------------------------------

output "project_bucket_name" {
  description = "Name of the project S3 bucket"
  value       = aws_s3_bucket.project.id
}

output "project_bucket_arn" {
  description = "ARN of the project S3 bucket"
  value       = aws_s3_bucket.project.arn
}

output "logs_bucket_name" {
  description = "Name of the logs S3 bucket"
  value       = aws_s3_bucket.logs.id
}

output "logs_bucket_arn" {
  description = "ARN of the logs S3 bucket"
  value       = aws_s3_bucket.logs.arn
}

# -----------------------------------------------------------------------------
# App Mesh
# -----------------------------------------------------------------------------

output "appmesh_id" {
  description = "ID of the AWS App Mesh"
  value       = aws_appmesh_mesh.this.id
}

output "appmesh_arn" {
  description = "ARN of the AWS App Mesh"
  value       = aws_appmesh_mesh.this.arn
}

output "appmesh_name" {
  description = "Name of the AWS App Mesh"
  value       = aws_appmesh_mesh.this.name
}
