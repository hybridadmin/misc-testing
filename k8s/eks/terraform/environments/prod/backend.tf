# Backend configuration for prod environment.
# Terraform state is stored in a separate S3 key per environment to ensure
# full isolation between systest and prod.
#
# Usage:
#   terraform init -backend-config=environments/prod/backend.tf

bucket         = "my-terraform-state-bucket"
key            = "eks/prod/terraform.tfstate"
region         = "us-west-2"
dynamodb_table = "terraform-lock"
encrypt        = true
