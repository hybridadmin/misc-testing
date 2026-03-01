# -----------------------------------------------------------------------------
# Root Terragrunt configuration
#
# This file is automatically included by every child terragrunt.hcl via
# include { path = find_in_parent_folders() }.
#
# It sets up:
#   1. Remote state (S3 + DynamoDB)
#   2. AWS provider generation with assume-role into each target account
# -----------------------------------------------------------------------------

locals {
  # Parse the account-level config from the nearest account.hcl
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
  aws_region   = local.account_vars.locals.aws_region

  # -------------------------------------------------------------------------
  # IMPORTANT: Update these values to match your environment
  # -------------------------------------------------------------------------
  state_bucket     = "my-org-terraform-state"
  state_lock_table = "terraform-locks"
  state_region     = "us-east-1"
  state_encrypt    = true
}

# -----------------------------------------------------------------------------
# Remote state -- S3 + DynamoDB
# -----------------------------------------------------------------------------
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = local.state_bucket
    key            = "${local.account_name}/${path_relative_to_include()}/terraform.tfstate"
    region         = local.state_region
    encrypt        = local.state_encrypt
    dynamodb_table = local.state_lock_table
  }
}

# -----------------------------------------------------------------------------
# Provider generation -- assume role into the target account
# -----------------------------------------------------------------------------
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      assume_role {
        role_arn = "arn:aws:iam::${local.account_id}:role/OrganizationAccountAccessRole"
      }

      default_tags {
        tags = {
          ManagedBy   = "terragrunt"
          AccountName = "${local.account_name}"
        }
      }
    }
  EOF
}
