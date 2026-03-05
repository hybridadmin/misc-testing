# Systest member eu-west-1 region override
locals {
  project     = "admin"
  environment = "systest"
  aws_region  = "eu-west-1"

  devops_account_id    = "555555555555"
  backup_account_id    = ""  # TODO: Not defined for systest in original CDK project
  backup_region        = "us-west-2"
  devops_event_bus_arn = "arn:aws:events:eu-west-1:555555555555:event-bus/default"
}
