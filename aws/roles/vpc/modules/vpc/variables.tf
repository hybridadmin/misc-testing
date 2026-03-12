###############################################################################
# General
###############################################################################

variable "project" {
  description = "Project name used for resource naming and tagging. Lowercase alphanumeric and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.project))
    error_message = "Project must be 3-30 characters, lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Controls default behaviours like NAT gateway count and flow log retention."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "uat", "qa", "sandbox"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, uat, qa, sandbox."
  }
}

variable "service" {
  description = "Service name used in resource naming. Defaults to 'network'."
  type        = string
  default     = "network"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,28}[a-z0-9]$", var.service))
    error_message = "Service must be lowercase alphanumeric and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Additional tags merged with default tags on all resources."
  type        = map(string)
  default     = {}
}

###############################################################################
# VPC
###############################################################################

variable "cidr_block" {
  description = "Primary IPv4 CIDR block for the VPC. Must be /16 to /28."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR notation (e.g. 10.0.0.0/16)."
  }
}

variable "secondary_cidr_blocks" {
  description = "List of secondary CIDR blocks to associate with the VPC for additional address space."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.secondary_cidr_blocks : can(cidrhost(cidr, 0))])
    error_message = "All secondary CIDR blocks must be valid IPv4 CIDR notation."
  }
}

variable "enable_dns_support" {
  description = "Enable DNS resolution within the VPC. Required for VPC endpoints and private hosted zones."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC. Required for public DNS resolution of EC2 instances."
  type        = bool
  default     = true
}

variable "instance_tenancy" {
  description = "Tenancy of instances launched in the VPC. 'default' uses shared hardware; 'dedicated' uses single-tenant hardware (significant cost increase)."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "dedicated"], var.instance_tenancy)
    error_message = "Instance tenancy must be 'default' or 'dedicated'."
  }
}

###############################################################################
# Availability Zones
###############################################################################

variable "availability_zones" {
  description = "List of availability zones for subnet placement. Must provide exactly 3 AZs for full redundancy."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly 3 availability zones must be specified for high availability across all subnet tiers."
  }
}

###############################################################################
# Subnets - Public
###############################################################################

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). These subnets host internet-facing resources (ALBs, NAT Gateways, bastion hosts)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == 3
    error_message = "Exactly 3 public subnet CIDRs must be specified (one per availability zone)."
  }

  validation {
    condition     = alltrue([for cidr in var.public_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "All public subnet CIDRs must be valid IPv4 CIDR notation."
  }
}

variable "public_subnet_map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses to instances launched in public subnets."
  type        = bool
  default     = true
}

###############################################################################
# Subnets - Private (Application)
###############################################################################

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private application subnets (one per AZ). These subnets host application workloads (ECS, EKS, Lambda, EC2)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 3
    error_message = "Exactly 3 private subnet CIDRs must be specified (one per availability zone)."
  }

  validation {
    condition     = alltrue([for cidr in var.private_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "All private subnet CIDRs must be valid IPv4 CIDR notation."
  }
}

###############################################################################
# Subnets - Database (Isolated)
###############################################################################

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets (one per AZ). These are isolated subnets with no direct internet ingress. Egress is allowed via NAT through private subnets for patching and secret rotation."
  type        = list(string)

  validation {
    condition     = length(var.database_subnet_cidrs) == 3
    error_message = "Exactly 3 database subnet CIDRs must be specified (one per availability zone)."
  }

  validation {
    condition     = alltrue([for cidr in var.database_subnet_cidrs : can(cidrhost(cidr, 0))])
    error_message = "All database subnet CIDRs must be valid IPv4 CIDR notation."
  }
}

variable "create_database_subnet_group" {
  description = "Create an RDS DB subnet group from the database subnets. Convenient for downstream RDS deployments."
  type        = bool
  default     = true
}

variable "database_subnet_group_name" {
  description = "Override name for the RDS DB subnet group. Auto-generated if empty."
  type        = string
  default     = ""
}

###############################################################################
# NAT Gateways
###############################################################################

variable "single_nat_gateway" {
  description = "Use a single NAT gateway for all private and database subnets. Recommended for dev/staging to reduce costs (~$32/month per NAT GW). Set to false for production to get one NAT per AZ for high availability."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Enable NAT gateways for outbound internet access from private and database subnets. Disable only if no outbound access is needed."
  type        = bool
  default     = true
}

###############################################################################
# Internet Gateway
###############################################################################

variable "create_igw" {
  description = "Create an internet gateway. Required for public subnet internet access and NAT gateways."
  type        = bool
  default     = true
}

###############################################################################
# VPC Flow Logs
###############################################################################

variable "enable_flow_logs" {
  description = "Enable VPC flow logs for network traffic monitoring and security analysis."
  type        = bool
  default     = true
}

variable "flow_log_destination_type" {
  description = "Destination type for flow logs. 'cloud-watch-logs' for real-time analysis, 's3' for cost-effective long-term storage."
  type        = string
  default     = "cloud-watch-logs"

  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.flow_log_destination_type)
    error_message = "Flow log destination must be 'cloud-watch-logs' or 's3'."
  }
}

variable "flow_log_traffic_type" {
  description = "Type of traffic to capture. 'ALL' captures accept and reject, 'REJECT' captures only denied traffic (cost saving)."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "Flow log traffic type must be 'ACCEPT', 'REJECT', or 'ALL'."
  }
}

variable "flow_log_retention_in_days" {
  description = "CloudWatch log group retention for flow logs in days. Ignored when destination is S3."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_in_days)
    error_message = "Flow log retention must be a valid CloudWatch log group retention value."
  }
}

variable "flow_log_max_aggregation_interval" {
  description = "Maximum interval (seconds) during which flow log records are aggregated before publishing. 60 for near real-time, 600 for cost optimization."
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.flow_log_max_aggregation_interval)
    error_message = "Flow log max aggregation interval must be 60 or 600 seconds."
  }
}

variable "flow_log_cloudwatch_kms_key_id" {
  description = "KMS key ARN for encrypting the CloudWatch flow log group. Uses AWS-managed key if empty."
  type        = string
  default     = ""
}

variable "flow_log_s3_bucket_arn" {
  description = "S3 bucket ARN for flow log delivery when destination type is 's3'. Required if flow_log_destination_type is 's3'."
  type        = string
  default     = ""
}

variable "flow_log_s3_key_prefix" {
  description = "S3 key prefix for flow log files. Helps organize logs in the bucket."
  type        = string
  default     = "vpc-flow-logs"
}

variable "flow_log_log_format" {
  description = "Custom flow log record format. Leave empty for the AWS default format. See AWS docs for available fields."
  type        = string
  default     = ""
}

###############################################################################
# VPC Endpoints
###############################################################################

variable "enable_s3_endpoint" {
  description = "Create a gateway VPC endpoint for S3. Eliminates NAT gateway charges for S3 traffic -- strongly recommended."
  type        = bool
  default     = true
}

variable "enable_dynamodb_endpoint" {
  description = "Create a gateway VPC endpoint for DynamoDB. Eliminates NAT gateway charges for DynamoDB traffic."
  type        = bool
  default     = true
}

variable "interface_endpoints" {
  description = "Map of interface VPC endpoints to create. Key is the service short name (e.g. 'ssm', 'secretsmanager', 'ecr.api'). Enable private_dns to resolve service endpoints to private IPs."
  type = map(object({
    service_name = string
    private_dns  = optional(bool, true)
    policy       = optional(string, null)
  }))
  default = {}

  # Example:
  # interface_endpoints = {
  #   ssm             = { service_name = "com.amazonaws.eu-west-1.ssm" }
  #   secretsmanager  = { service_name = "com.amazonaws.eu-west-1.secretsmanager" }
  #   ecr_api         = { service_name = "com.amazonaws.eu-west-1.ecr.api" }
  #   ecr_dkr         = { service_name = "com.amazonaws.eu-west-1.ecr.dkr" }
  # }
}

variable "interface_endpoint_security_group_ids" {
  description = "Additional security group IDs to attach to interface VPC endpoints. A default SG allowing HTTPS from the VPC CIDR is always created."
  type        = list(string)
  default     = []
}

###############################################################################
# Network ACLs
###############################################################################

variable "create_custom_nacls" {
  description = "Create custom Network ACLs for each subnet tier. When false, subnets use the VPC default NACL (allow all)."
  type        = bool
  default     = true
}

variable "public_nacl_ingress_rules" {
  description = "Additional custom ingress rules for the public subnet NACL. Default rules already allow HTTP/HTTPS/ephemeral ports."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "public_nacl_egress_rules" {
  description = "Additional custom egress rules for the public subnet NACL."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "private_nacl_ingress_rules" {
  description = "Additional custom ingress rules for the private subnet NACL."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "private_nacl_egress_rules" {
  description = "Additional custom egress rules for the private subnet NACL."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "database_nacl_ingress_rules" {
  description = "Additional custom ingress rules for the database subnet NACL. Default rules only allow traffic from private subnets on database ports."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "database_nacl_egress_rules" {
  description = "Additional custom egress rules for the database subnet NACL."
  type = list(object({
    rule_number = number
    protocol    = string
    rule_action = string
    cidr_block  = string
    from_port   = number
    to_port     = number
  }))
  default = []
}

variable "database_allowed_ports" {
  description = "List of database ports to allow inbound from private subnets in the database NACL (e.g. 5432 for PostgreSQL, 3306 for MySQL, 6379 for Redis)."
  type        = list(number)
  default     = [5432, 3306, 6379]

  validation {
    condition     = alltrue([for p in var.database_allowed_ports : p >= 1 && p <= 65535])
    error_message = "All database ports must be between 1 and 65535."
  }
}

###############################################################################
# Cost Optimization
###############################################################################

variable "enable_network_address_usage_metrics" {
  description = "Enable network address usage metrics for the VPC. Helps track IP address utilization."
  type        = bool
  default     = false
}

###############################################################################
# Custom Identifier
###############################################################################

variable "identifier_override" {
  description = "Override the auto-generated name prefix for all resources. When empty, uses '<project>-<environment>-<service>'."
  type        = string
  default     = ""

  validation {
    condition     = var.identifier_override == "" || can(regex("^[a-z][a-z0-9-]{1,60}[a-z0-9]$", var.identifier_override))
    error_message = "Identifier override must be empty or lowercase alphanumeric with hyphens, 3-62 chars."
  }
}
