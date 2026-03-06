# Backend configuration for systest environment.
# Terraform state is stored in a separate S3 key per environment to ensure
# full isolation between systest and prod.
#
# Usage:
#   terraform init -backend-config=environments/systest/backend.tf

bucket         = "my-terraform-state-bucket"
key            = "eks/systest/terraform.tfstate"
region         = "us-west-2"
dynamodb_table = "terraform-lock"
encrypt        = true
