variable "name_prefix" {
  description = "Prefix for all resource names (e.g. CICD-BUILD)"
  type        = string
  default     = "CICD-BUILD"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.10.0/24"

  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "enable_dns_support" {
  description = "Enable DNS support in the VPC"
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC"
  type        = bool
  default     = false
}

variable "ssm_parameter_paths" {
  description = "List of SSM parameter ARN patterns the factory role can read (e.g. SSH keys)"
  type        = list(string)
  default = [
    "arn:aws:ssm:eu-west-1:*:parameter/private_key_orgadmin",
    "arn:aws:ssm:eu-west-1:*:parameter/private-key-orgadmin",
  ]
}

variable "software_bucket_name" {
  description = "Name of the S3 bucket containing AMI build software"
  type        = string
  default     = "myorg-ami-software"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
