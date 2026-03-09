# Root terragrunt.hcl - provides common configuration for all environments
#
# This file is included by all child terragrunt.hcl files and provides:
# - Remote state configuration (S3 + DynamoDB)
# - Common provider configuration
# - Default tags

locals {
  # Parse the file path to extract environment and region information
  # Expected path structure: environments/<env>/<component>/<region>/terragrunt.hcl
  # or: environments/<env>/<component>/terragrunt.hcl (when region is in the dir name)
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  project     = local.env_vars.locals.project
  environment = local.env_vars.locals.environment
  aws_region  = local.env_vars.locals.aws_region

  # Common tags applied to all resources
  common_tags = {
    project     = local.project
    environment = local.environment
    service     = "backups"
    managed_by  = "terragrunt"
  }
}

# Configure Terraform to store state in S3 with DynamoDB locking
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.project}-${local.environment}-terraform-state"
    key            = "backups/${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "${local.project}-${local.environment}-terraform-locks"
  }
}

# Generate provider configuration
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = ${jsonencode(local.common_tags)}
      }
    }
  EOF
}
