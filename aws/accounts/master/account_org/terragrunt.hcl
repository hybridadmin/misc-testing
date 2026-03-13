# Root terragrunt.hcl - shared configuration for all environments
# This file is included by all child terragrunt.hcl files.

locals {
  # Parse the file path to extract account and region
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
  aws_region   = local.region_vars.locals.aws_region
}

# Generate the provider block
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  # Assume role into the target account (uncomment and configure as needed)
  # assume_role {
  #   role_arn = "arn:aws:iam::${local.account_id}:role/TerraformExecutionRole"
  # }

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Environment = "${local.account_name}"
      Region      = "${local.aws_region}"
    }
  }
}
EOF
}

# Configure remote state (S3 backend)
remote_state {
  backend = "s3"
  config = {
    encrypt        = true
    bucket         = "terraform-state-${local.account_id}-${local.aws_region}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    dynamodb_table = "terraform-locks"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Common inputs passed to all modules
inputs = {
  tags = {
    ManagedBy   = "terraform"
    Environment = local.account_name
    Region      = local.aws_region
  }
}
