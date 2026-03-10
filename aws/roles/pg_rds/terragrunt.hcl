# -----------------------------------------------------------------------------
# Root terragrunt.hcl
#
# Common configuration inherited by all child terragrunt.hcl files.
# Handles:
#   - Remote state (S3 + DynamoDB locking)
#   - AWS provider generation with assume-role into target accounts
#   - Common input variables
# -----------------------------------------------------------------------------

locals {
  # Parse the file path to extract environment and region from the directory structure.
  # Layout: environments/<environment>/<region>/pg_rds/terragrunt.hcl
  parsed      = regex(".+/environments/(?P<env>[^/]+)/(?P<region>[^/]+)/.*", get_terragrunt_dir())
  environment = local.parsed.env
  aws_region  = local.parsed.region

  # Load environment-level variables
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  project = local.env_vars.locals.project
  service = local.env_vars.locals.service

  # Account ID: prefer account.hcl (per-account override) if present, otherwise use env.hcl default.
  account_vars = try(read_terragrunt_config("${get_terragrunt_dir()}/../account.hcl"), null)
  account_id   = try(local.account_vars.locals.account_id, local.env_vars.locals.account_id)
}

# -----------------------------------------------------------------------------
# Remote state - S3 backend with DynamoDB locking
# -----------------------------------------------------------------------------
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.project}-${local.environment}-tfstate-${local.account_id}"
    key            = "${local.service}/${local.aws_region}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "${local.project}-${local.environment}-tfstate-lock"

    skip_bucket_versioning = false
  }
}

# -----------------------------------------------------------------------------
# Provider generation - assumes a role in the target account
# -----------------------------------------------------------------------------
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      assume_role {
        role_arn = "arn:aws:iam::${local.account_id}:role/${local.project}-terraform-execution"
      }

      default_tags {
        tags = {
          project     = "${local.project}"
          environment = "${local.environment}"
          service     = "${local.service}"
          managed_by  = "terragrunt"
        }
      }
    }
  EOF
}

# -----------------------------------------------------------------------------
# Provider version constraints
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Common inputs passed to all modules
# -----------------------------------------------------------------------------
inputs = {
  project     = local.project
  environment = local.environment
  service     = local.service
}
