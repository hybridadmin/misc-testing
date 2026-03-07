---
name: terraform-state-safety
description: Enforce Terraform remote state best practices including S3 backend with encryption, DynamoDB state locking, and state file hygiene
---

## Purpose

Protect Terraform state files from corruption, concurrent modification, and unauthorized access. State files contain sensitive data and are the single source of truth for managed infrastructure.

## When to use

- When setting up a new Terraform project or environment
- When reviewing backend configuration
- When onboarding new environments (dev, staging, prod)
- When auditing state management practices

## Rules

### 1. Always use remote backends

Never use local state for shared or production infrastructure. Use S3 backend with these required settings:

```hcl
terraform {
  backend "s3" {
    bucket         = "<project>-terraform-state"
    key            = "<service>/<environment>/terraform.tfstate"
    region         = "<region>"
    encrypt        = true
    dynamodb_table = "<project>-terraform-locks"
    kms_key_id     = "<kms-key-arn>"  # Use a dedicated KMS key
  }
}
```

### 2. Enable state locking

- ALWAYS configure a DynamoDB table for state locking
- The DynamoDB table must use `LockID` as the partition key (String type)
- State locking prevents concurrent `terraform apply` from corrupting state
- Never use `-lock=false` in production

### 3. Encrypt state at rest

- Set `encrypt = true` in the backend config (uses SSE-S3 by default)
- Prefer specifying `kms_key_id` to use a customer-managed KMS key (SSE-KMS)
- The state file contains secrets (passwords, tokens, private keys) -- encryption is mandatory

### 4. Protect the state bucket

The S3 bucket holding state files must have:
- Versioning enabled (to recover from accidental overwrites)
- `force_destroy = false`
- `lifecycle { prevent_destroy = true }`
- A bucket policy restricting access to authorized IAM roles only
- Public access blocked (`aws_s3_bucket_public_access_block`)
- Server-side encryption configured as default

### 5. Use consistent state key paths

Organize state keys by service and environment:
```
<service>/<environment>/terraform.tfstate
```

Examples:
```
eks/prod/terraform.tfstate
eks/systest/terraform.tfstate
networking/prod/terraform.tfstate
```

### 6. Never store secrets in Terraform state intentionally

- Use `sensitive = true` on outputs that contain secrets
- Prefer referencing secrets from AWS Secrets Manager or SSM Parameter Store
- Never hardcode passwords or tokens in `.tf` files or `.tfvars`

### 7. State file operations

- Never manually edit `.tfstate` files
- Use `terraform state mv` for renaming resources, not manual edits
- Use `terraform import` to bring existing resources under management
- Use `terraform state rm` only when you understand the consequences
- Always back up state before `terraform state` operations

### 8. Backend configuration per environment

Each environment MUST have its own state file with a unique key path. Never share state between environments. Use separate backend configs:

```
environments/
  prod/
    backend.tf      # key = "eks/prod/terraform.tfstate"
  systest/
    backend.tf      # key = "eks/systest/terraform.tfstate"
```
