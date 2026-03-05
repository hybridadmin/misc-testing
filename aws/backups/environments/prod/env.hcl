# Production environment common variables
locals {
  project     = "admin"
  environment = "prod"
  aws_region  = "eu-west-1"  # Default region, overridden per-component

  # Account IDs
  devops_account_id  = "555555555555"
  backup_account_id  = "777777777777"
  master_account_id  = "854944599301"
  mgmt_account_id    = "888888888888"
  cicd_account_id    = "444444444444"

  # Backup configuration
  backup_region = "us-west-2"

  # Organization
  organization_id         = "o-pfayzcebx5"
  organization_arn        = "arn:aws:organizations::888888888888:organization/o-k4k3t4y98z"
  production_ou_path      = "o-pfayzcebx5/r-zkdv/ou-zkdv-a0k0yvv1"

  # SNS topics (imported from statics stack)
  general_notification_topic_arn  = "arn:aws:sns:eu-west-1:555555555555:ADMIN-PROD-application-events-general"
  critical_notification_topic_arn = "arn:aws:sns:eu-west-1:555555555555:ADMIN-PROD-application-events-critical"

  # DevOps event bus for event forwarding
  devops_event_bus_arn = "arn:aws:events:eu-west-1:555555555555:event-bus/default"

  # Route 53 backup config
  route53_config = ["888888888888"]

  # AMI encryption key
  ami_encryption_kms_key_arn = "arn:aws:kms:us-west-2:444444444444:alias/cicd-prod-AmiEncryption"
}
