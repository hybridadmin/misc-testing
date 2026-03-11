# Override for devops-central region
locals {
  project     = "admin"
  environment = "prod"
  aws_region  = "eu-west-1"

  devops_account_id  = "555555555555"
  backup_account_id  = "777777777777"
  backup_region      = "us-west-2"

  general_notification_topic_arn  = "arn:aws:sns:eu-west-1:555555555555:ADMIN-PROD-application-events-general"
  critical_notification_topic_arn = "arn:aws:sns:eu-west-1:555555555555:ADMIN-PROD-application-events-critical"

  route53_config                 = ["888888888888"]
  organization_arn               = "arn:aws:organizations::888888888888:organization/o-k4k3t4y98z"
  ami_encryption_kms_key_arn     = "arn:aws:kms:us-west-2:444444444444:alias/cicd-prod-AmiEncryption"
}
