###############################################################################
# General
###############################################################################

variable "project" {
  description = "Project name used for resource naming and tagging."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project))
    error_message = "Project name must contain only lowercase alphanumeric characters and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "uat", "qa", "sandbox"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, uat, qa, sandbox."
  }
}

variable "service" {
  description = "Service or application name that owns this database."
  type        = string
  default     = "postgres"
}

variable "tags" {
  description = "Additional tags to merge with the default tags applied to all resources."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking
###############################################################################

variable "vpc_id" {
  description = "ID of the VPC where the RDS instance will be deployed."
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group. Use private subnets."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnet IDs are required for multi-AZ deployments."
  }
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to connect to the RDS instance."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "List of security group IDs allowed to connect to the RDS instance."
  type        = list(string)
  default     = []
}

###############################################################################
# Engine Configuration
###############################################################################

variable "engine_version" {
  description = "PostgreSQL engine version (e.g. 14.10, 15.5, 16.1)."
  type        = string
  default     = "16.1"
}

variable "family" {
  description = "The DB parameter group family (e.g. postgres14, postgres15, postgres16). If empty, derived from engine_version."
  type        = string
  default     = ""
}

###############################################################################
# Instance Configuration
###############################################################################

variable "instance_class" {
  description = "The RDS instance class (e.g. db.t3.micro, db.r6g.large, db.r6g.xlarge)."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Initial storage allocation in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536
    error_message = "Allocated storage must be between 20 and 65536 GiB."
  }
}

variable "max_allocated_storage" {
  description = "Upper limit for storage autoscaling in GiB. Set to 0 to disable autoscaling."
  type        = number
  default     = 100

  validation {
    condition     = var.max_allocated_storage == 0 || var.max_allocated_storage >= 20
    error_message = "Max allocated storage must be 0 (disabled) or >= 20 GiB."
  }
}

variable "storage_type" {
  description = "Storage type: gp2, gp3, or io1."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.storage_type)
    error_message = "Storage type must be one of: gp2, gp3, io1, io2."
  }
}

variable "iops" {
  description = "Provisioned IOPS. Only applicable for io1/io2 and gp3 storage types."
  type        = number
  default     = null
}

variable "storage_throughput" {
  description = "Storage throughput in MiB/s. Only applicable for gp3."
  type        = number
  default     = null
}

variable "storage_encrypted" {
  description = "Whether to encrypt the DB storage at rest."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "ARN of the KMS key for storage encryption. Uses the default aws/rds key if empty."
  type        = string
  default     = ""
}

###############################################################################
# Database Configuration
###############################################################################

variable "db_name" {
  description = "Name of the default database to create. Set to empty string to skip creation."
  type        = string
  default     = ""
}

variable "db_port" {
  description = "Port on which the database accepts connections."
  type        = number
  default     = 5432
}

variable "master_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "pgadmin"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.master_username))
    error_message = "Master username must start with a letter and contain only alphanumeric characters and underscores."
  }
}

variable "manage_master_user_password" {
  description = "Whether to let RDS manage the master user password in Secrets Manager."
  type        = bool
  default     = true
}

variable "master_user_secret_kms_key_id" {
  description = "KMS key ID for encrypting the master user secret in Secrets Manager. Uses default if empty."
  type        = string
  default     = ""
}

###############################################################################
# High Availability & Replication
###############################################################################

variable "multi_az" {
  description = "Enable Multi-AZ deployment for high availability."
  type        = bool
  default     = false
}

variable "availability_zone" {
  description = "Preferred AZ for single-AZ deployments. Leave empty for AWS-selected."
  type        = string
  default     = null
}

variable "read_replicas" {
  description = "Map of read replicas to create. Key is the replica identifier suffix."
  type = map(object({
    instance_class    = optional(string)
    availability_zone = optional(string)
    storage_encrypted = optional(bool, true)
    kms_key_id        = optional(string, "")
    publicly_accessible = optional(bool, false)
    tags              = optional(map(string), {})
  }))
  default = {}
}

###############################################################################
# Backup & Recovery
###############################################################################

variable "backup_retention_period" {
  description = "Number of days to retain automated backups (0 to disable)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "Backup retention period must be between 0 and 35 days."
  }
}

variable "backup_window" {
  description = "Preferred UTC time range for automated backups (e.g. 03:00-04:00)."
  type        = string
  default     = "03:00-04:00"
}

variable "copy_tags_to_snapshot" {
  description = "Copy all instance tags to snapshots."
  type        = bool
  default     = true
}

variable "delete_automated_backups" {
  description = "Whether to delete automated backups when the instance is deleted."
  type        = bool
  default     = true
}

variable "snapshot_identifier" {
  description = "Snapshot ID to restore from. Leave empty for a fresh instance."
  type        = string
  default     = null
}

variable "final_snapshot_identifier_prefix" {
  description = "Prefix for the final snapshot taken on instance deletion."
  type        = string
  default     = "final"
}

variable "skip_final_snapshot" {
  description = "Skip taking a final snapshot on deletion. Should be false for production."
  type        = bool
  default     = false
}

###############################################################################
# Maintenance
###############################################################################

variable "maintenance_window" {
  description = "Preferred UTC time range for maintenance (e.g. Sun:05:00-Sun:06:00)."
  type        = string
  default     = "Sun:05:00-Sun:06:00"
}

variable "auto_minor_version_upgrade" {
  description = "Allow automatic minor engine version upgrades during maintenance."
  type        = bool
  default     = true
}

variable "allow_major_version_upgrade" {
  description = "Allow major engine version upgrades. Requires manual apply_immediately."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply changes immediately instead of during the next maintenance window."
  type        = bool
  default     = false
}

###############################################################################
# Network & Access
###############################################################################

variable "publicly_accessible" {
  description = "Whether the DB instance is publicly accessible. Should be false for production."
  type        = bool
  default     = false
}

variable "ca_cert_identifier" {
  description = "Identifier of the CA certificate for the DB instance."
  type        = string
  default     = "rds-ca-rsa2048-g1"
}

###############################################################################
# Monitoring & Logging
###############################################################################

variable "performance_insights_enabled" {
  description = "Enable Performance Insights."
  type        = bool
  default     = true
}

variable "performance_insights_retention_period" {
  description = "Retention period for Performance Insights data in days (7, 31, 62, 93, 124, ..., 731)."
  type        = number
  default     = 7
}

variable "performance_insights_kms_key_id" {
  description = "KMS key ARN for Performance Insights encryption. Uses default if empty."
  type        = string
  default     = null
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0, 1, 5, 10, 15, 30, 60). 0 disables."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "Monitoring interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "monitoring_role_arn" {
  description = "ARN of an existing IAM role for Enhanced Monitoring. If empty, a role will be created."
  type        = string
  default     = ""
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to CloudWatch (postgresql, upgrade)."
  type        = list(string)
  default     = ["postgresql", "upgrade"]

  validation {
    condition     = alltrue([for log in var.enabled_cloudwatch_logs_exports : contains(["postgresql", "upgrade"], log)])
    error_message = "Valid PostgreSQL log exports are: postgresql, upgrade."
  }
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Number of days to retain CloudWatch log group entries."
  type        = number
  default     = 30
}

variable "cloudwatch_log_group_kms_key_id" {
  description = "KMS key ARN for encrypting CloudWatch log groups."
  type        = string
  default     = null
}

###############################################################################
# CloudWatch Alarms
###############################################################################

variable "create_cloudwatch_alarms" {
  description = "Whether to create CloudWatch alarms for the RDS instance."
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arns" {
  description = "List of SNS topic ARNs to notify on alarm state changes."
  type        = list(string)
  default     = []
}

variable "alarm_cpu_threshold" {
  description = "CPU utilization threshold percentage for the alarm."
  type        = number
  default     = 80
}

variable "alarm_memory_threshold" {
  description = "Freeable memory threshold in bytes for the alarm (default ~128 MiB)."
  type        = number
  default     = 134217728
}

variable "alarm_storage_threshold" {
  description = "Free storage space threshold in bytes for the alarm (default ~2 GiB)."
  type        = number
  default     = 2147483648
}

variable "alarm_read_latency_threshold" {
  description = "Read latency threshold in seconds for the alarm."
  type        = number
  default     = 0.02
}

variable "alarm_write_latency_threshold" {
  description = "Write latency threshold in seconds for the alarm."
  type        = number
  default     = 0.05
}

variable "alarm_connections_threshold" {
  description = "Database connections threshold for the alarm."
  type        = number
  default     = 100
}

###############################################################################
# Parameter Group
###############################################################################

variable "parameter_group_parameters" {
  description = "List of additional DB parameter group parameters to set."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

###############################################################################
# Deletion Protection
###############################################################################

variable "deletion_protection" {
  description = "Prevent accidental deletion of the database instance."
  type        = bool
  default     = true
}

variable "iam_database_authentication_enabled" {
  description = "Enable IAM database authentication."
  type        = bool
  default     = false
}

###############################################################################
# Blue/Green Deployments
###############################################################################

variable "blue_green_update_enabled" {
  description = "Enable blue/green deployment for safer upgrades."
  type        = bool
  default     = false
}

###############################################################################
# Custom Identifier
###############################################################################

variable "identifier_override" {
  description = "Override the auto-generated RDS identifier. Leave empty to use the default naming convention."
  type        = string
  default     = ""
}
