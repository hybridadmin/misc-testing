# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire, prodct)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

variable "service" {
  description = "Service name"
  type        = string
  default     = "bastion"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the ASG and bastion placement"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Instance Configuration
# -----------------------------------------------------------------------------

variable "ami_id" {
  description = "AMI ID for the bastion host"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ssh_port" {
  description = "SSH port for the bastion host"
  type        = number
  default     = 22
}

# -----------------------------------------------------------------------------
# SSH / VPN Access
# -----------------------------------------------------------------------------

variable "vpn_cidrs" {
  description = "List of VPN server CIDRs allowed SSH access"
  type = list(object({
    cidr        = string
    description = string
  }))
  default = []
}

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------

variable "icinga_ips" {
  description = "List of Icinga monitoring server IPs (without /32 suffix)"
  type        = list(string)
  default     = []
}

variable "cpu_warning_threshold" {
  description = "CPU utilisation percentage threshold for CloudWatch alarm"
  type        = number
  default     = 80
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch log group logs"
  type        = number
  default     = 180
}

# -----------------------------------------------------------------------------
# SNS
# -----------------------------------------------------------------------------

variable "sns_topic_arns" {
  description = "List of SNS topic ARNs [critical, general] for alarm actions and notifications"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# S3
# -----------------------------------------------------------------------------

variable "project_bucket_arn" {
  description = "ARN of the project S3 bucket"
  type        = string
}

variable "project_bucket_name" {
  description = "Name of the project S3 bucket"
  type        = string
}

variable "authorized_users_bucket" {
  description = "S3 bucket name for authorized_users (e.g. moya-internal)"
  type        = string
  default     = "moya-internal"
}

# -----------------------------------------------------------------------------
# EFS
# -----------------------------------------------------------------------------

variable "efs_filesystem_id" {
  description = "EFS filesystem ID for persistent bastion storage"
  type        = string
}

# -----------------------------------------------------------------------------
# Route53 / DNS
# -----------------------------------------------------------------------------

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for this environment"
  type        = string
}

variable "route53_zone_ids" {
  description = "List of all Route53 hosted zone IDs the bastion may manage records in"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Service Discovery
# -----------------------------------------------------------------------------

variable "service_discovery_namespace_id" {
  description = "Cloud Map namespace ID for service discovery"
  type        = string
}

# -----------------------------------------------------------------------------
# Git / Init
# -----------------------------------------------------------------------------

variable "git_repo_url" {
  description = "Git repo URL cloned during instance init"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
