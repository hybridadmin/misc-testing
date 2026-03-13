variable "devops_account_id" {
  description = "AWS account ID of the DevOps/CI-CD account that will assume the deployment role"
  type        = string

  validation {
    condition     = can(regex("^\\d{12}$", var.devops_account_id))
    error_message = "Account ID must be exactly 12 digits."
  }
}

variable "packer_account_ids" {
  description = "List of AWS account IDs allowed to run Packer builds (EC2 image factory operations)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.packer_account_ids : can(regex("^\\d{12}$", id))])
    error_message = "All account IDs must be exactly 12 digits."
  }
}

variable "deployment_role_name" {
  description = "Name of the cross-account deployment role"
  type        = string
  default     = "ORGRoleForDevopsDeployment"
}

variable "cfn_execution_policy_name" {
  description = "Name of the CloudFormation execution managed policy"
  type        = string
  default     = "ORGPolicyForCfnExecution"
}

variable "stackset_execution_role_name" {
  description = "Name of the StackSet execution role"
  type        = string
  default     = "AWSCloudFormationStackSetExecutionRole"
}

variable "stackset_admin_role_name" {
  description = "Name of the StackSet administration role"
  type        = string
  default     = "AWSCloudFormationStackSetAdministrationRole"
}

variable "factory_profile_prefix" {
  description = "Prefix for the EC2 factory instance profile name (e.g. CICD-BUILD)"
  type        = string
  default     = "CICD-BUILD"
}

variable "factory_role_prefix" {
  description = "Prefix for the EC2 factory role name (e.g. CICD-BUILD)"
  type        = string
  default     = "CICD-BUILD"
}

variable "devops_kms_key_arns" {
  description = "List of KMS key ARNs in the DevOps account used for AMI encryption"
  type        = list(string)
  default     = []
}

variable "deployment_bucket_regions" {
  description = "List of regions where deployment S3 buckets exist"
  type        = list(string)
  default     = ["eu-west-1", "af-south-1"]
}

variable "cdk_qualifier" {
  description = "CDK bootstrap qualifier"
  type        = string
  default     = "hnb659fds"
}

variable "configuration_bucket_name" {
  description = "Name of the shared configuration S3 bucket"
  type        = string
  default     = "myorg-build-configuration"
}

variable "additional_cfn_via_services" {
  description = "Additional AWS regions for CloudFormation service principal (e.g. af-south-1 opt-in regions)"
  type        = list(string)
  default     = ["af-south-1"]
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
