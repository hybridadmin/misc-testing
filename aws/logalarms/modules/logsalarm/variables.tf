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
  default     = "logsalarm"
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
  default     = "python3.13"
}

variable "lambda_memory_size" {
  description = "Memory allocated to the Lambda function (MB)"
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "lambda_architectures" {
  description = "Instruction set architecture for the Lambda function"
  type        = list(string)
  default     = ["arm64"]
}

variable "log_retention_days" {
  description = "Number of days to retain Lambda CloudWatch log group logs"
  type        = number
  default     = 30
}

variable "lambda_source_path" {
  description = "Path to the Lambda source file"
  type        = string
}

##--------------------------------------------------------------
## Tags
##--------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
