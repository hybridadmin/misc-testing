---
name: terraform-security
description: Enforce Terraform security best practices including least-privilege IAM, encryption at rest, no hardcoded secrets, and secure defaults
---

## Purpose

Ensure all Terraform-managed infrastructure follows security best practices to prevent privilege escalation, data exposure, and compliance violations.

## When to use

- When creating or modifying any IAM role, policy, or security group
- When provisioning any resource that stores or transmits data
- When reviewing Terraform code for security posture
- Before merging any infrastructure pull request

## Rules

### 1. IAM: Least privilege

- NEVER use `"Resource": "*"` with mutating actions (write/delete). Read-only describe/list actions on `*` are acceptable when scoping is impractical.
- ALWAYS scope IAM policies to specific resource ARNs where possible
- Use condition keys to further restrict access (e.g., `aws:ResourceTag`, `aws:RequestedRegion`)
- Prefer AWS-managed policies over custom policies when they provide the right scope
- IRSA (IAM Roles for Service Accounts) roles MUST use `StringEquals` conditions on both `:aud` and `:sub` claims

```hcl
condition {
  test     = "StringEquals"
  variable = "${oidc_provider}:aud"
  values   = ["sts.amazonaws.com"]
}
condition {
  test     = "StringEquals"
  variable = "${oidc_provider}:sub"
  values   = ["system:serviceaccount:<namespace>:<service-account>"]
}
```

### 2. Encryption at rest

Every data store MUST be encrypted:

| Resource | Encryption Attribute |
|---|---|
| `aws_s3_bucket` | `aws_s3_bucket_server_side_encryption_configuration` with KMS |
| `aws_db_instance` | `storage_encrypted = true`, `kms_key_id` |
| `aws_rds_cluster` | `storage_encrypted = true`, `kms_key_id` |
| `aws_ebs_volume` | `encrypted = true`, `kms_key_id` |
| `aws_efs_file_system` | `encrypted = true`, `kms_key_id` |
| `aws_dynamodb_table` | `server_side_encryption { enabled = true, kms_key_arn }` |
| `aws_eks_cluster` | `encryption_config` block for secrets |
| `aws_cloudwatch_log_group` | `kms_key_id` |
| `aws_sqs_queue` | `kms_master_key_id` |
| `aws_sns_topic` | `kms_master_key_id` |

- Use customer-managed KMS keys (CMK) for production workloads
- Enable KMS key rotation: `enable_key_rotation = true`

### 3. Encryption in transit

- EKS API endpoints: enable private access, restrict public access
- Load balancers: use HTTPS listeners with TLS 1.2+ policies
- RDS: `require_ssl = true` via parameter groups
- S3: enforce `aws:SecureTransport` condition in bucket policies

### 4. No hardcoded secrets

- NEVER put passwords, API keys, tokens, or certificates directly in `.tf` or `.tfvars` files
- Use `aws_secretsmanager_secret` or `aws_ssm_parameter` to reference secrets
- Mark sensitive outputs: `sensitive = true`
- Add `*.tfvars` to `.gitignore` if they contain environment-specific values that could leak

### 5. Security groups

- NEVER allow `0.0.0.0/0` on ingress rules unless explicitly required (e.g., public ALBs on 443)
- Prefer security group references (`source_security_group_id`) over CIDR blocks for internal traffic
- Always add a `description` to every security group rule
- Egress to `0.0.0.0/0` is acceptable for nodes that need internet access via NAT

### 6. Network isolation

- Run workloads in private subnets
- Use NAT gateways for outbound-only internet access
- Enable VPC Flow Logs for all VPCs (for audit and forensics)
- EKS API: prefer `endpoint_private_access = true`, restrict `endpoint_public_access` to known CIDRs

### 7. Logging and auditing

- Enable EKS control plane logging: `["api", "audit", "authenticator", "controllerManager", "scheduler"]`
- Enable VPC Flow Logs with CloudWatch or S3 destination
- Set appropriate log retention (minimum 90 days for compliance)
- Never delete CloudWatch log groups without archival

### 8. KMS key management

- Set `deletion_window_in_days = 30` (maximum) for all KMS keys
- Enable automatic key rotation: `enable_key_rotation = true`
- Use separate KMS keys per service/purpose (not one shared key)
- Add `lifecycle { prevent_destroy = true }` to all KMS keys
