---
name: terraform-modules
description: Enforce Terraform module design best practices including structure, variable validation, outputs, dependency management, and versioning
---

## Purpose

Ensure Terraform modules are well-structured, reusable, maintainable, and follow consistent conventions for input validation, output exposure, and dependency management.

## When to use

- When creating a new Terraform module
- When refactoring existing modules
- When reviewing module interfaces (variables, outputs)
- When structuring a multi-environment Terraform project

## Rules

### 1. Module file structure

Every module MUST follow this file layout:

```
modules/<name>/
  main.tf          # Resource definitions
  variables.tf     # Input variable declarations
  outputs.tf       # Output value declarations
  versions.tf      # Required provider versions (optional, can be in root)
```

- Keep `main.tf` focused. If it exceeds ~300 lines, split by logical concern (e.g., `iam.tf`, `networking.tf`)
- Never put variable declarations in `main.tf` or resource definitions in `variables.tf`

### 2. Variable conventions

- Every variable MUST have a `description`
- Every variable MUST have an explicit `type`
- Use `validation` blocks for inputs with constrained value sets:

```hcl
variable "environment" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["dev", "systest", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, systest, staging, prod."
  }
}
```

- Use `sensitive = true` for variables that may contain secrets
- Provide sensible `default` values where appropriate, but NEVER default critical values (e.g., CIDR blocks, instance types, cluster names)

### 3. Output conventions

- Every output MUST have a `description`
- Expose IDs, ARNs, and names needed by downstream modules
- Use `sensitive = true` for outputs containing secrets
- Prefix outputs logically (e.g., `vpc_id`, `cluster_endpoint`, `node_role_arn`)

### 4. Module composition

Structure the root module to orchestrate child modules:

```hcl
module "vpc" {
  source = "./modules/vpc"
  # ...
}

module "eks" {
  source = "./modules/eks"
  vpc_id = module.vpc.vpc_id
  # ...
}

module "addons" {
  source     = "./modules/addons"
  cluster_name = module.eks.cluster_name
  # ...
}
```

- Pass values between modules via outputs, never via `terraform_remote_state` within the same configuration
- Keep the root module thin -- it should primarily wire modules together

### 5. Version constraints

- Pin the minimum Terraform version in `versions.tf`:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- Use pessimistic version constraints (`~>`) for providers to allow patch updates
- Pin Helm chart versions in `helm_release` resources (never use `latest`)

### 6. Environment separation

- Use `terraform.tfvars` per environment with a shared module structure:

```
environments/
  prod/
    backend.tf
    terraform.tfvars
  systest/
    backend.tf
    terraform.tfvars
```

- Never use `count` or conditionals to differentiate environments. Use different variable values instead.
- Each environment gets its own state file (see terraform-state-safety skill)

### 7. Dependency management

- Use `depends_on` sparingly and only for implicit dependencies Terraform cannot detect
- Prefer data flow dependencies (passing outputs as inputs) over explicit `depends_on`
- Document non-obvious `depends_on` with inline comments explaining why

### 8. Naming conventions

- Module directories: lowercase with hyphens (`modules/eks`, `modules/vpc`)
- Resource names: snake_case, descriptive (`aws_iam_role.cluster`, not `aws_iam_role.r1`)
- Local values: snake_case
- Variables: snake_case with clear nouns (`cluster_name`, `node_instance_types`)
- Avoid abbreviations unless universally understood (`vpc`, `eks`, `iam` are fine)

### 9. Code formatting

- Always run `terraform fmt` before committing
- Use consistent indentation (2 spaces, Terraform default)
- Group resource arguments logically: required args first, then optional, then tags, then lifecycle/depends_on last

### 10. Documentation

- Add header comments to `main.tf` explaining the module's purpose
- Add section comments (`# ---`) to group related resources
- Document non-obvious design decisions inline
- Keep a root-level README with usage instructions and required inputs
