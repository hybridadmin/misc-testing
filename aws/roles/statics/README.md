# Statics - Persistent Resources Terraform Module

Terragrunt-managed Terraform module for provisioning persistent resources with
a lifecycle outside the VPC. Includes SNS topics for application events, S3
buckets (project data + logs with ELB/VPC flow log policies), and an AWS App
Mesh.

**Ported from:** Ansible + CloudFormation (`roles/statics/files/template.json`)

## Architecture

```
                     ┌──────────────────────────────────────────────┐
                     │                 AWS Account                  │
                     │                                              │
                     │  ┌───────────────────┐  ┌────────────────┐  │
                     │  │  SNS Topics       │  │  AWS App Mesh  │  │
                     │  │  ├── *-critical   │  │  ALLOW_ALL     │  │
                     │  │  └── *-general    │  │  egress        │  │
                     │  │    └── Lambda sub  │  └────────────────┘  │
                     │  └───────────────────┘                      │
                     │                                              │
                     │  ┌───────────────────┐  ┌────────────────┐  │
                     │  │  Project Bucket   │  │  Logs Bucket   │  │
                     │  │  KMS encrypted    │  │  AES256        │  │
                     │  │  Versioned        │  │  180d lifecycle │  │
                     │  │  Public blocked   │  │  Bucket policy: │  │
                     │  │  BucketOwner      │  │  ├── ELB logs   │  │
                     │  │  Enforced         │  │  └── VPC flow   │  │
                     │  └───────────────────┘  └────────────────┘  │
                     └──────────────────────────────────────────────┘
```

## Resources Created

| Resource | Description |
|----------|-------------|
| `aws_sns_topic` (critical) | SNS topic for critical application events |
| `aws_sns_topic` (general) | SNS topic for general application events |
| `aws_sns_topic_subscription` | Lambda subscriptions (optional, per topic) |
| `aws_lambda_permission` | Allow SNS to invoke Lambda (optional) |
| `aws_s3_bucket` (project) | Project bucket with KMS encryption + versioning |
| `aws_s3_bucket` (logs) | Logs bucket with AES256 + lifecycle rules |
| `aws_s3_bucket_public_access_block` | Public access blocked on both buckets |
| `aws_s3_bucket_server_side_encryption_configuration` | Encryption config per bucket |
| `aws_s3_bucket_ownership_controls` | BucketOwnerEnforced on both buckets |
| `aws_s3_bucket_versioning` | Versioning on project bucket |
| `aws_s3_bucket_lifecycle_configuration` | 180-day expiration on logs bucket |
| `aws_s3_bucket_policy` | ELB access logging + VPC flow log delivery |
| `aws_appmesh_mesh` | App Mesh with ALLOW_ALL egress filter |

## Project Structure

```
statics/
├── terragrunt.hcl                          # Root config
├── _envcommon/
│   └── statics.hcl                         # Shared component config
├── modules/
│   └── statics/
│       ├── main.tf                         # Terraform resources
│       ├── variables.tf                    # Module input variables
│       └── outputs.tf                      # Module outputs
├── envs/
│   ├── systest/
│   │   ├── env.hcl
│   │   └── eu-west-1/statics/terragrunt.hcl
│   └── prodire/
│       ├── env.hcl
│       ├── eu-west-1/statics/terragrunt.hcl
│       └── af-south-1/statics/terragrunt.hcl
├── scripts/
│   └── generate_account_dirs.sh
├── .gitignore
└── README.md
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI** v2 (for `generate_account_dirs.sh`)
- An IAM role `<project>-terraform-execution` in each target account
- (Optional) SNS-to-Email Lambda function for topic subscriptions

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier |
| `service` | `string` | Service identifier (always `statics`) |
| `environment` | `string` | Environment name |
| `account_id` | `string` | Default AWS account ID |
| `sns_to_email_lambda_arn` | `string` | ARN of SNS-to-Email Lambda (empty to skip) |
| `logs_expiration_days` | `number` | Days before log objects expire (default: 180) |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"statics"` | Service identifier |
| `aws_region` | `string` | - | AWS region |
| `sns_to_email_lambda_arn` | `string` | `""` | Lambda ARN for SNS subscriptions |
| `logs_expiration_days` | `number` | `180` | Log bucket object expiration |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `sns_topic_critical_arn` | ARN of the critical events SNS topic |
| `sns_topic_critical_name` | Name of the critical events SNS topic |
| `sns_topic_general_arn` | ARN of the general events SNS topic |
| `sns_topic_general_name` | Name of the general events SNS topic |
| `project_bucket_name` | Project S3 bucket name |
| `project_bucket_arn` | Project S3 bucket ARN |
| `logs_bucket_name` | Logs S3 bucket name |
| `logs_bucket_arn` | Logs S3 bucket ARN |
| `appmesh_id` | AWS App Mesh ID |
| `appmesh_arn` | AWS App Mesh ARN |
| `appmesh_name` | AWS App Mesh name |

## Deployment

### Single Account

```bash
cd envs/systest/eu-west-1/statics
terragrunt plan && terragrunt apply
```

### Multi-Account

```bash
./scripts/generate_account_dirs.sh prodire
cd envs/prodire && terragrunt run-all plan
```

## Important Notes

- S3 buckets have `prevent_destroy = true` lifecycle rules. To destroy, you
  must first remove the lifecycle block or use `terraform state rm`.
- The ELB access logging bucket policy uses a region-to-account-ID mapping
  covering 15 AWS regions. If deploying to an unlisted region, the ELB
  logging statement is automatically omitted.
- SNS topic subscriptions to the Lambda function are optional. Set
  `sns_to_email_lambda_arn` to an empty string to create topics without
  subscriptions.

## Remote State Layout

```
Bucket: <project>-<environment>-tfstate-<account_id>
Key:    statics/<region>/terraform.tfstate
```

## Porting Notes (CloudFormation to Terraform)

| CloudFormation | Terraform |
|----------------|-----------|
| `AWS::SNS::Topic` with inline `Subscription` | `aws_sns_topic` + `aws_sns_topic_subscription` + `aws_lambda_permission` |
| `AWS::S3::Bucket` with inline encryption/versioning | Separate resources per S3 configuration aspect |
| `AWS::S3::BucketPolicy` with `Fn::FindInMap` | `aws_s3_bucket_policy` with HCL `lookup()` map |
| `AWS::AppMesh::Mesh` | `aws_appmesh_mesh` |
| `Mappings.RegionELBAccountIdMap` | `locals.elb_account_id_map` HCL map |
| `DeletionPolicy: Retain` | `lifecycle { prevent_destroy = true }` |
| Stack exports | Terraform outputs |

### Key Improvements Over Original

- **Separate S3 configuration resources** following Terraform best practices
- **Conditional SNS subscriptions** -- Lambda subscription is optional
- **Lambda permission** added for SNS -> Lambda invocation (missing in original)
- **Dynamic ELB account ID** lookup with graceful fallback for unsupported regions
- **Multi-account/region support** via Terragrunt directory structure
