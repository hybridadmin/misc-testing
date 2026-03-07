---
name: terraform-tagging
description: Enforce consistent resource tagging strategy across all Terraform-managed AWS resources for cost allocation, ownership, and compliance
---

## Purpose

Ensure all AWS resources are consistently tagged for cost tracking, ownership identification, environment segregation, automation, and compliance auditing.

## When to use

- When creating any new Terraform resource that supports tags
- When reviewing existing resources for tagging compliance
- When setting up a new module or environment
- When troubleshooting cost allocation or resource ownership

## Rules

### 1. Required tags on every resource

All taggable resources MUST have these tags, passed via a shared `var.tags` map:

| Tag Key | Description | Example |
|---|---|---|
| `Environment` | Deployment environment | `prod`, `systest`, `dev` |
| `Project` | Project or service name | `eks-platform` |
| `ManagedBy` | Tool managing the resource | `terraform` |
| `Owner` | Team or individual responsible | `platform-team` |

### 2. Pass tags via a common variable

Define a `tags` variable in every module and pass it from the root:

```hcl
variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
```

Root module should merge base tags:

```hcl
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

module "vpc" {
  source = "./modules/vpc"
  tags   = local.common_tags
  # ...
}
```

### 3. Resource-specific name tags

In addition to common tags, every resource SHOULD have a `Name` tag using `merge()`:

```hcl
tags = merge(var.tags, {
  Name = "${var.name}-<resource-descriptor>"
})
```

### 4. Kubernetes-specific tags

For EKS integration, subnets and security groups need additional tags:

**Public subnets (for external ALBs):**
```hcl
"kubernetes.io/role/elb"                   = "1"
"kubernetes.io/cluster/${cluster_name}"    = "shared"
```

**Private subnets (for internal ALBs):**
```hcl
"kubernetes.io/role/internal-elb"          = "1"
"kubernetes.io/cluster/${cluster_name}"    = "shared"
```

**Node groups (for Cluster Autoscaler):**
```hcl
"k8s.io/cluster-autoscaler/enabled"               = "true"
"k8s.io/cluster-autoscaler/${cluster_name}"        = "owned"
```

### 5. Compliance tags

For regulated environments, add compliance-specific tags:

```hcl
Compliance   = "soc2"       # or "hipaa", "pci-dss", etc.
DataClass    = "internal"   # or "confidential", "public"
```

### 6. Cost allocation tags

Ensure these tags are activated in AWS Cost Explorer:
- `Environment`
- `Project`
- `Owner`

This enables cost breakdown by environment, project, and team.

### 7. Do not tag with volatile values

Never tag with values that change frequently (e.g., timestamps, commit SHAs). This causes unnecessary resource updates on every apply.

### 8. Use default_tags provider feature

When available, use the AWS provider `default_tags` block to reduce repetition:

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "terraform"
    }
  }
}
```

Note: `default_tags` does not work with all resources and can cause conflicts with explicit tags. Test before adopting broadly.
