# -----------------------------------------------------------------------------
# envs/prod/env.hcl
#
# Environment-level variables for the production environment.
# Full HA, encryption, monitoring, and strict deletion protection.
# -----------------------------------------------------------------------------

locals {
  project     = "myproject"
  service     = "postgres"
  environment = "prod"
  account_id  = "222222222222"   # Replace with your production account ID

  # Networking -- replace with your actual VPC and subnet IDs
  vpc_id     = "vpc-xxxxxxxxxxxxxxxxx"
  subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-yyyyyyyyyyyyyyyyy", "subnet-zzzzzzzzzzzzzzzzz"]

  # Engine
  engine_version = "16.1"

  # Instance -- production-grade
  instance_class        = "db.r6g.large"
  allocated_storage     = 100
  max_allocated_storage = 500

  # HA -- always enabled in production
  multi_az = true

  # Backup -- maximum retention
  backup_retention_period = 35
  skip_final_snapshot     = false
  deletion_protection     = true

  # Monitoring -- aggressive intervals
  monitoring_interval                   = 5
  performance_insights_enabled          = true
  performance_insights_retention_period = 31

  # Alarms
  create_cloudwatch_alarms = true
  alarm_sns_topic_arns     = []   # Add your production SNS topic ARN(s)

  # Access -- restrict to specific application subnets
  allowed_cidr_blocks        = ["10.0.0.0/8"]
  allowed_security_group_ids = []   # Add application security group IDs

  # Maintenance -- changes applied during maintenance windows only
  apply_immediately          = false
  auto_minor_version_upgrade = false

  # Read replicas for production read scaling
  read_replicas = {
    reader1 = {
      instance_class = "db.r6g.large"
    }
  }
}
