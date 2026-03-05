# Member accounts env.hcl - shared config for all member account regions
locals {
  project     = "admin"
  environment = "prod"
  aws_region  = "eu-west-1"  # Default, overridden per-region directory

  devops_account_id  = "555555555555"
  backup_account_id  = "777777777777"
  backup_region      = "us-west-2"
  devops_event_bus_arn = "arn:aws:events:eu-west-1:555555555555:event-bus/default"
}
