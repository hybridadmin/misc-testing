# Root Terragrunt configuration for DevOps Bootstrap
#
# Automatically included by every child terragrunt.hcl via
# include { path = find_in_parent_folders() }.
#
# Sets up:
#   1. Remote state (S3 + DynamoDB)
#   2. AWS provider generation for the DevOps account

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
  aws_region   = local.account_vars.locals.aws_region

  # Remote state configuration
  state_bucket     = "myorg-terraform-state"
  state_lock_table = "terraform-locks"
  state_region     = "eu-west-1"
  state_encrypt    = true
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = local.state_bucket
    key            = "devops-bootstrap/${path_relative_to_include()}/terraform.tfstate"
    region         = local.state_region
    encrypt        = local.state_encrypt
    dynamodb_table = local.state_lock_table
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          ManagedBy   = "terragrunt"
          AccountName = "${local.account_name}"
          Project     = "devops-bootstrap"
        }
      }
    }
  EOF
}
