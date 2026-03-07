---
name: terraform-deletion-protection
description: Ensure all critical Terraform resources have deletion protection via lifecycle prevent_destroy and provider-level deletion_protection attributes
---

## Purpose

Prevent accidental destruction of critical infrastructure by enforcing deletion protection on all Terraform resources that would cause significant disruption, data loss, or extended downtime if deleted.

## When to use

- When creating or reviewing any Terraform resource definition
- When adding new infrastructure modules
- When auditing existing Terraform manifests for safety gaps
- Before any `terraform apply` or `terraform destroy` review

## Rules

### 1. Always add `lifecycle { prevent_destroy = true }` to these resource types

These resources MUST have `prevent_destroy = true` in their lifecycle block:

**Compute & Orchestration:**
- `aws_eks_cluster`
- `aws_eks_node_group`
- `aws_ecs_cluster`
- `aws_instance` (stateful instances)

**Networking:**
- `aws_vpc`
- `aws_subnet`
- `aws_internet_gateway`
- `aws_nat_gateway`
- `aws_eip` (Elastic IPs used by NAT gateways or allowlisted externally)
- `aws_security_group` (control plane and node security groups)

**Data & Storage:**
- `aws_db_instance` / `aws_rds_cluster`
- `aws_s3_bucket`
- `aws_dynamodb_table`
- `aws_efs_file_system`
- `aws_elasticache_cluster`

**Encryption & Secrets:**
- `aws_kms_key`
- `aws_kms_alias`

**Identity & Access:**
- `aws_iam_role` (service-linked and IRSA roles)
- `aws_iam_policy` (custom policies)
- `aws_iam_openid_connect_provider`

**Observability & Compliance:**
- `aws_cloudwatch_log_group` (audit and compliance logs)

### 2. Use provider-level deletion protection where available

Some AWS resources support a `deletion_protection` attribute at the API level. This MUST be enabled in addition to `prevent_destroy`:

| Resource | Attribute | Value |
|---|---|---|
| `aws_eks_cluster` | `deletion_protection` | `"ENABLED"` |
| `aws_db_instance` | `deletion_protection` | `true` |
| `aws_rds_cluster` | `deletion_protection` | `true` |
| `aws_lb` | `enable_deletion_protection` | `true` |
| `aws_elasticache_cluster` | `deletion_protection` | `true` |

### 3. Set safe KMS key deletion windows

- KMS keys MUST have `deletion_window_in_days` set to `30` (the maximum)
- Never use the minimum of `7` in production

### 4. S3 bucket protection

- Set `force_destroy = false` (or omit it, as `false` is the default)
- Enable bucket versioning to protect against accidental object deletion
- Consider enabling Object Lock for compliance-critical buckets

### 5. When prevent_destroy is NOT needed

Do NOT add `prevent_destroy` to:
- Leaf/dependent resources: route table associations, security group rules, IAM policy attachments
- Ephemeral resources: `null_resource`, `random_*`, `local_file`
- Resources that can be recreated without impact: `aws_route`, `aws_route_table`
- Helm releases (managed at the Kubernetes layer, not AWS)
- EKS addons (can be reinstalled without data loss)

### 6. Merging with existing lifecycle blocks

When a resource already has a `lifecycle` block (e.g., `create_before_destroy` or `ignore_changes`), add `prevent_destroy` to the SAME block:

```hcl
lifecycle {
  create_before_destroy = true
  ignore_changes        = [tags]
  prevent_destroy       = true
}
```

Never create duplicate lifecycle blocks on the same resource.

## Verification

After adding protection, verify by running:
```bash
grep -rn "prevent_destroy" modules/
```

Count should match the number of critical resources. Cross-reference against the resource inventory to ensure nothing was missed.
