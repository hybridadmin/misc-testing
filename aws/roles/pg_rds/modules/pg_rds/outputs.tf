###############################################################################
# Primary Instance
###############################################################################

output "db_instance_id" {
  description = "The RDS instance identifier."
  value       = aws_db_instance.this.id
}

output "db_instance_arn" {
  description = "The ARN of the RDS instance."
  value       = aws_db_instance.this.arn
}

output "db_instance_endpoint" {
  description = "The connection endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "db_instance_address" {
  description = "The hostname of the RDS instance."
  value       = aws_db_instance.this.address
}

output "db_instance_port" {
  description = "The port the database is listening on."
  value       = aws_db_instance.this.port
}

output "db_instance_name" {
  description = "The name of the default database."
  value       = aws_db_instance.this.db_name
}

output "db_instance_username" {
  description = "The master username."
  value       = aws_db_instance.this.username
}

output "db_instance_resource_id" {
  description = "The RDS Resource ID (for IAM auth)."
  value       = aws_db_instance.this.resource_id
}

output "db_instance_status" {
  description = "The current status of the RDS instance."
  value       = aws_db_instance.this.status
}

output "db_instance_engine_version_actual" {
  description = "The running engine version."
  value       = aws_db_instance.this.engine_version_actual
}

output "db_instance_availability_zone" {
  description = "The AZ where the instance is deployed."
  value       = aws_db_instance.this.availability_zone
}

###############################################################################
# Master User Secret (Secrets Manager)
###############################################################################

output "db_instance_master_user_secret_arn" {
  description = "The ARN of the Secrets Manager secret containing the master user password."
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}

###############################################################################
# Networking
###############################################################################

output "db_subnet_group_name" {
  description = "The DB subnet group name."
  value       = aws_db_subnet_group.this.name
}

output "db_subnet_group_arn" {
  description = "The ARN of the DB subnet group."
  value       = aws_db_subnet_group.this.arn
}

output "security_group_id" {
  description = "The security group ID attached to the RDS instance."
  value       = aws_security_group.this.id
}

output "security_group_arn" {
  description = "The ARN of the security group."
  value       = aws_security_group.this.arn
}

###############################################################################
# Parameter Group
###############################################################################

output "db_parameter_group_name" {
  description = "The DB parameter group name."
  value       = aws_db_parameter_group.this.name
}

output "db_parameter_group_arn" {
  description = "The ARN of the DB parameter group."
  value       = aws_db_parameter_group.this.arn
}

###############################################################################
# Monitoring
###############################################################################

output "enhanced_monitoring_role_arn" {
  description = "The ARN of the Enhanced Monitoring IAM role."
  value       = local.create_monitoring_role ? aws_iam_role.enhanced_monitoring[0].arn : var.monitoring_role_arn
}

###############################################################################
# Read Replicas
###############################################################################

output "read_replica_endpoints" {
  description = "Map of read replica identifiers to their connection endpoints."
  value = {
    for k, v in aws_db_instance.replica : k => {
      endpoint = v.endpoint
      address  = v.address
      port     = v.port
      arn      = v.arn
    }
  }
}

###############################################################################
# CloudWatch
###############################################################################

output "cloudwatch_log_group_arns" {
  description = "Map of CloudWatch log group names to ARNs."
  value = {
    for k, v in aws_cloudwatch_log_group.this : k => v.arn
  }
}

###############################################################################
# Convenience Outputs
###############################################################################

output "connection_info" {
  description = "Connection information for the RDS instance."
  value = {
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    database = aws_db_instance.this.db_name
    username = aws_db_instance.this.username
    engine   = "postgres"
    version  = aws_db_instance.this.engine_version_actual
  }
}
