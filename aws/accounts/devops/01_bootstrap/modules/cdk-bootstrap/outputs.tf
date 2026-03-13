output "staging_bucket_name" {
  description = "Name of the CDK staging S3 bucket"
  value       = aws_s3_bucket.staging.id
}

output "staging_bucket_arn" {
  description = "ARN of the CDK staging S3 bucket"
  value       = aws_s3_bucket.staging.arn
}

output "staging_bucket_domain_name" {
  description = "Regional domain name of the CDK staging S3 bucket"
  value       = aws_s3_bucket.staging.bucket_regional_domain_name
}

output "ecr_repository_name" {
  description = "Name of the ECR repository for container assets"
  value       = aws_ecr_repository.assets.name
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository for container assets"
  value       = aws_ecr_repository.assets.arn
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for container assets"
  value       = aws_ecr_repository.assets.repository_url
}

output "file_publishing_role_arn" {
  description = "ARN of the file publishing IAM role"
  value       = aws_iam_role.file_publishing.arn
}

output "image_publishing_role_arn" {
  description = "ARN of the image publishing IAM role"
  value       = aws_iam_role.image_publishing.arn
}

output "lookup_role_arn" {
  description = "ARN of the lookup IAM role"
  value       = aws_iam_role.lookup.arn
}

output "deploy_role_arn" {
  description = "ARN of the deployment action IAM role"
  value       = aws_iam_role.deploy.arn
}

output "cfn_exec_role_arn" {
  description = "ARN of the CloudFormation execution IAM role"
  value       = aws_iam_role.cfn_exec.arn
}

output "assets_kms_key_arn" {
  description = "ARN of the KMS key for asset encryption (empty if not created)"
  value       = local.create_new_key ? aws_kms_key.assets[0].arn : ""
}

output "bootstrap_version" {
  description = "The CDK bootstrap version"
  value       = aws_ssm_parameter.bootstrap_version.value
}

output "bootstrap_version_ssm_parameter" {
  description = "Name of the SSM parameter storing the bootstrap version"
  value       = aws_ssm_parameter.bootstrap_version.name
}
