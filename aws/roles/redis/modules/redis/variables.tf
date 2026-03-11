# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------

variable "project" {
  description = "Project identifier"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. systest, prodire)"
  type        = string
}

variable "service" {
  description = "Service identifier"
  type        = string
  default     = "redis"
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where the Redis security group will be created"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block - used for Redis ingress rule on port 6379"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the ElastiCache subnet group (one per AZ)"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Cluster Configuration
# -----------------------------------------------------------------------------

variable "node_type" {
  description = "ElastiCache node instance type (e.g. cache.t4g.micro, cache.r7g.large)"
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Valkey engine version"
  type        = string
  default     = "7.2"
}

variable "parameter_family" {
  description = "ElastiCache parameter group family (must match engine version)"
  type        = string
  default     = "valkey7"
}

variable "num_shards" {
  description = "Number of node groups (shards) in the cluster. Use 1 for a single-shard replication group."
  type        = number
  default     = 1
}

variable "replicas_per_shard" {
  description = "Number of read replicas per shard. Set to at least 1 for multi-AZ automatic failover."
  type        = number
  default     = 1
}

variable "parameters" {
  description = "List of Valkey parameter overrides. Each element must have 'name' and 'value' keys."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

# -----------------------------------------------------------------------------
# Maintenance & Snapshots
# -----------------------------------------------------------------------------

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC). Format: ddd:hh24:mi-ddd:hh24:mi"
  type        = string
  default     = "sun:03:00-sun:04:00"
}

variable "snapshot_window" {
  description = "Daily snapshot window (UTC). Format: hh24:mi-hh24:mi. Must not overlap maintenance_window."
  type        = string
  default     = "01:00-02:00"
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic snapshots. Set to 0 to disable."
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# Operations
# -----------------------------------------------------------------------------

variable "apply_immediately" {
  description = "Whether changes should be applied immediately or during the next maintenance window"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Encryption
# -----------------------------------------------------------------------------

variable "use_custom_kms_key" {
  description = "Whether to create a customer-managed KMS key for at-rest encryption. When false, ElastiCache uses the free AWS-managed key instead (saves ~$1/month)."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
