###############################################################################
# Root Terragrunt Configuration
#
# This file is included by all child terragrunt.hcl files. It provides:
#   - Remote state configuration (S3 + DynamoDB)
#   - Provider generation
#   - Common input variables
###############################################################################

# ---------------------------------------------------------------------------
# Load account-level and region-level variables
# ---------------------------------------------------------------------------

locals {
  # Load account-level variables (account_name, aws_account_id, aws_profile)
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  # Load region-level variables (aws_region)
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  # Extract commonly used values
  account_name   = local.account_vars.locals.account_name
  account_id     = local.account_vars.locals.aws_account_id
  aws_profile    = local.account_vars.locals.aws_profile
  aws_region     = local.region_vars.locals.aws_region

  # Project-level settings
  project_name   = "google-sso"
  state_bucket   = "terraform-state-${local.account_id}-${local.aws_region}"
  dynamodb_table = "terraform-locks"
}

# ---------------------------------------------------------------------------
# Remote State — S3 backend with DynamoDB locking
# ---------------------------------------------------------------------------

remote_state {
  backend = "s3"

  config = {
    encrypt        = true
    bucket         = local.state_bucket
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    dynamodb_table = local.dynamodb_table

    # Enable bucket versioning for state file recovery
    skip_bucket_versioning = false

    # Tags for the S3 bucket and DynamoDB table
    s3_bucket_tags = {
      Name        = "Terraform State - ${local.project_name}"
      Environment = local.account_name
      ManagedBy   = "terragrunt"
    }

    dynamodb_table_tags = {
      Name        = "Terraform Locks - ${local.project_name}"
      Environment = local.account_name
      ManagedBy   = "terragrunt"
    }
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# ---------------------------------------------------------------------------
# Provider Generation
# ---------------------------------------------------------------------------

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region  = "${local.aws_region}"
      profile = "${local.aws_profile}"

      default_tags {
        tags = {
          Project     = "${local.project_name}"
          Environment = "${local.account_name}"
          ManagedBy   = "terraform"
          Repository  = "google_sso"
        }
      }
    }
  EOF
}

# ---------------------------------------------------------------------------
# Terraform Version Constraint
# ---------------------------------------------------------------------------

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.5.0"

      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }
  EOF
}

# ---------------------------------------------------------------------------
# Common Inputs
# ---------------------------------------------------------------------------

inputs = {
  tags = {
    Project     = local.project_name
    Environment = local.account_name
    ManagedBy   = "terraform"
  }
}
