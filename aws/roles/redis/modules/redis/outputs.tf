output "replication_group_id" {
  description = "ElastiCache replication group ID"
  value       = aws_elasticache_replication_group.redis.id
}

output "replication_group_arn" {
  description = "ElastiCache replication group ARN"
  value       = aws_elasticache_replication_group.redis.arn
}

output "primary_endpoint_address" {
  description = "Primary endpoint address. Returns configuration_endpoint_address for cluster-mode (num_shards > 1) or primary_endpoint_address for single-shard mode."
  value = (
    var.num_shards > 1
    ? aws_elasticache_replication_group.redis.configuration_endpoint_address
    : aws_elasticache_replication_group.redis.primary_endpoint_address
  )
}

output "reader_endpoint_address" {
  description = "Reader endpoint address for read replicas"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "port" {
  description = "Valkey port"
  value       = aws_elasticache_replication_group.redis.port
}

output "security_group_id" {
  description = "Security group ID for the Valkey cluster"
  value       = aws_security_group.redis.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for at-rest encryption (null when using AWS-managed key)"
  value       = var.use_custom_kms_key ? aws_kms_key.redis[0].arn : null
}

output "kms_key_id" {
  description = "ID of the KMS key used for at-rest encryption (null when using AWS-managed key)"
  value       = var.use_custom_kms_key ? aws_kms_key.redis[0].key_id : null
}

output "subnet_group_name" {
  description = "Name of the ElastiCache subnet group"
  value       = aws_elasticache_subnet_group.redis.name
}

output "parameter_group_name" {
  description = "Name of the ElastiCache parameter group"
  value       = aws_elasticache_parameter_group.redis.name
}
