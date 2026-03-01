# Backup Vault -- Terraform Module

Reusable Terraform module that creates a complete DR (disaster recovery) backup infrastructure in a dedicated backup account. This includes a KMS key, AWS Backup vault, S3 bucket for file-based backups, and a cross-account IAM role that source accounts assume to push backups.

Converted from the `backup-account/template.yml` CloudFormation template.

## Resources Created

### KMS Key

| Resource | Purpose |
|---|---|
| `aws_kms_key.backup` | Customer-managed KMS key for backup vault and bucket encryption |
| `aws_kms_alias.backup` | Human-readable alias for the key |

### AWS Backup Vault

| Resource | Purpose |
|---|---|
| `aws_backup_vault.this` | Encrypted backup vault for AWS Backup recovery points |
| `aws_backup_vault_policy.this` | Vault access policy allowing organisation-wide `CopyIntoBackupVault` |
| `aws_backup_vault_notifications.this` | SNS notifications for vault events (e.g. `COPY_JOB_FAILED`) |

### S3 Backup Bucket

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.backup` | Versioned, KMS-encrypted bucket for file-based DR backups |
| `aws_s3_bucket_versioning.backup` | Enables object versioning |
| `aws_s3_bucket_public_access_block.backup` | Blocks public ACLs and policies |
| `aws_s3_bucket_ownership_controls.backup` | Sets `BucketOwnerPreferred` ownership |
| `aws_s3_bucket_server_side_encryption_configuration.backup` | KMS SSE with bucket keys |
| `aws_s3_bucket_lifecycle_configuration.backup` | Expires objects and noncurrent versions after retention period |
| `aws_s3_bucket_policy.backup` | Grants read access to specified OU paths |

### Cross-Account IAM Role

| Resource | Purpose |
|---|---|
| `aws_iam_role.cross_account_backup` | Role assumed by source accounts to perform backups |
| `aws_iam_role_policy.kms_access` | Allows `kms:GenerateDataKey` on the backup KMS key |
| `aws_iam_role_policy.s3_access` | Allows `s3:PutObject*` to the backup bucket |
| `aws_iam_role_policy.ec2_copy_image` | EC2 AMI copy, tagging, deregister, and KMS operations |
| `aws_iam_role_policy.ecr_copy_image` | ECR repository and image management for container backup |

## Architecture

```
┌──────────────────────────┐
│  Source Account(s)       │
│  (e.g. 394848222143)    │
│                          │
│  sts:AssumeRole ─────────┼──────────────┐
└──────────────────────────┘              │
                                          v
                               ┌──────────────────────┐
                               │  Backup Account       │
                               │                       │
                               │  ┌─────────────────┐  │
                               │  │ KMS Key (CMK)   │  │
                               │  └────────┬────────┘  │
                               │           │           │
                               │  ┌────────v────────┐  │
                               │  │ Backup Vault    │  │
                               │  │ (AWS Backup)    │  │
                               │  └─────────────────┘  │
                               │                       │
                               │  ┌─────────────────┐  │
                               │  │ S3 Bucket       │  │
                               │  │ (file backups)  │  │
                               │  └─────────────────┘  │
                               │                       │
                               │  ┌─────────────────┐  │
                               │  │ IAM Role        │  │
                               │  │ (cross-account) │  │
                               │  └─────────────────┘  │
                               └──────────────────────┘
```

## Usage

```hcl
module "backup_vault" {
  source = "../../modules/backup-vault"

  name            = "hbdorg-prod-backups"
  organization_id = "o-pfayzcebx5"

  backup_source_account_ids = ["394848222143"]
  sns_topic_arn             = "arn:aws:sns:eu-west-1:444444444444:devops-events-general"
  cross_account_role_name   = "HBDORG-PROD-BACKUP-CrossAccountBackupRole"
  bucket_read_org_paths     = ["o-pfayzcebx5/r-zkdv/ou-zkdv-a0k0yvv1"]

  tags = {
    Environment = "prod"
    ManagedBy   = "terragrunt"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Base name for the backup vault, KMS alias, and S3 bucket prefix. | `string` | n/a | **yes** |
| `organization_id` | AWS Organizations ID used to scope vault copy access. | `string` | n/a | **yes** |
| `backup_source_account_ids` | Account IDs allowed to assume the backup role and access the KMS key. | `list(string)` | n/a | **yes** |
| `sns_topic_arn` | ARN of the SNS topic for backup vault event notifications. | `string` | n/a | **yes** |
| `cross_account_role_name` | Name of the IAM role source accounts assume for backups. | `string` | n/a | **yes** |
| `bucket_read_org_paths` | Organizations paths allowed read access to the backup bucket. | `list(string)` | n/a | **yes** |
| `notification_events` | Backup vault events that trigger SNS notifications. | `list(string)` | `["COPY_JOB_FAILED"]` | no |
| `admin_role_name` | Name of the IAM role granted KMS key administration permissions. | `string` | `"CrossAccountAdminAccess"` | no |
| `backup_retention_days` | Days before S3 backup objects expire (current and noncurrent). | `number` | `180` | no |
| `kms_key_description` | Description of the KMS key. | `string` | `"AWS Backup Vault CMK"` | no |
| `kms_deletion_window_in_days` | Days before the KMS key is permanently deleted (7-30). | `number` | `30` | no |
| `enable_key_rotation` | Whether to enable automatic annual rotation of key material. | `bool` | `true` | no |
| `tags` | A map of tags to apply to all resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `kms_key_arn` | ARN of the backup vault KMS key. |
| `kms_key_id` | ID of the backup vault KMS key. |
| `kms_alias_arn` | ARN of the backup vault KMS key alias. |
| `vault_arn` | ARN of the AWS Backup vault. |
| `vault_name` | Name of the AWS Backup vault. |
| `bucket_arn` | ARN of the backup S3 bucket. |
| `bucket_name` | Name of the backup S3 bucket. |
| `cross_account_role_arn` | ARN of the cross-account backup IAM role. |
| `cross_account_role_name` | Name of the cross-account backup IAM role. |

## Lifecycle Protection

The following resources have `prevent_destroy = true` to guard against accidental deletion (mirroring the CloudFormation `DeletionPolicy: Retain`):

- `aws_kms_key.backup`
- `aws_backup_vault.this`
- `aws_s3_bucket.backup`

To destroy these resources, you must first remove the lifecycle block from the module code.

## Security Notes

- **KMS key rotation** is enabled by default.
- **KMS key policy** restricts backup service access via `kms:ViaService` and `kms:CallerAccount` conditions -- only the backup account itself and explicitly listed source accounts can use the key through AWS Backup.
- **Vault access policy** allows `backup:CopyIntoBackupVault` only from principals within the specified organisation (`aws:PrincipalOrgID`).
- **S3 bucket** is versioned, KMS-encrypted with bucket keys, and blocks public access. Read access is scoped to specific OU paths via `aws:PrincipalOrgPaths`.
- **Cross-account role** follows least privilege -- each policy is scoped to the minimum actions needed (KMS data key generation, S3 put, EC2 AMI copy, ECR image management).
- **S3 lifecycle** automatically expires objects after the configured retention period (default 180 days) to control storage costs.
