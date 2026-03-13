# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

##--------------------------------------------------------------
## General
##--------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service name"
  type        = string
  default     = "ecr"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

##--------------------------------------------------------------
## Lambda
##--------------------------------------------------------------

variable "lambda_runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "python3.12"
}

variable "lambda_memory_size" {
  description = "Memory allocated to the Lambda functions (MB)"
  type        = number
  default     = 512
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 600
}

variable "lambda_architectures" {
  description = "Instruction set architecture for the Lambda functions"
  type        = list(string)
  default     = ["arm64"]
}

variable "log_retention_days" {
  description = "Number of days to retain Lambda CloudWatch log group logs"
  type        = number
  default     = 30
}

##--------------------------------------------------------------
## Lambda source paths
##--------------------------------------------------------------

variable "add_permissions_source_path" {
  description = "Path to the add_permissions Lambda source file"
  type        = string
}

variable "attach_policy_source_path" {
  description = "Path to the attach_policy Lambda source file"
  type        = string
}

##--------------------------------------------------------------
## ECR cross-account access
##--------------------------------------------------------------

variable "ecr_pull_account_ids" {
  description = "List of AWS account IDs to grant ECR image pull access"
  type        = list(string)
  default     = []
}

variable "ecr_push_account_ids" {
  description = "List of AWS account IDs to grant ECR image push access"
  type        = list(string)
  default     = []
}

##--------------------------------------------------------------
## Feature flags
##--------------------------------------------------------------

variable "enable_lifecycle_policy" {
  description = "Whether to enable automatic ECR lifecycle policy attachment on new repositories"
  type        = bool
  default     = false
}

variable "lifecycle_max_image_count" {
  description = "Maximum number of images to retain per repository (when lifecycle policy is enabled)"
  type        = number
  default     = 10
}

##--------------------------------------------------------------
## Tags
##--------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
