# PSQL (PGO Postgres) IAM Role - Terraform Module

Terragrunt-managed Terraform module for provisioning IAM roles for PGO
(Postgres Operator) managed PostgreSQL clusters on EKS. The role is trusted
by three service accounts (instance, pgbackrest, repohost) and has policies
for SSM/Secrets Manager access and S3 backup bucket operations.

**Ported from:** Ansible + CloudFormation (`roles/psql/files/template.json`)

## Architecture

```
                     ┌──────────────────────────────────────────┐
                     │              AWS Account                 │
                     │                                          │
                     │  ┌────────────────────────────────────┐  │
                     │  │        IAM Role (IRSA)             │  │
                     │  │                                    │  │
                     │  │  Trust: EKS OIDC Provider          │  │
                     │  │  SAs:                              │  │
                     │  │   ├── <cluster>-instance           │  │
                     │  │   ├── <cluster>-pgbackrest         │  │
                     │  │   └── <cluster>-repohost           │  │
                     │  │                                    │  │
                     │  │  Policies:                         │  │
                     │  │   ├── Secrets Manager (GetSecret)  │  │
                     │  │   ├── SSM Parameters (Get/List)    │  │
                     │  │   └── S3 Backup Bucket             │  │
                     │  │       (Get/Put/Delete/List)         │  │
                     │  └────────────────────────────────────┘  │
                     │                                          │
                     │  S3: postgres-operator-<env>-backups-*   │
                     └──────────────────────────────────────────┘
```

## Resources Created

| Resource | Description |
|----------|-------------|
| `aws_iam_role` | IAM role with OIDC trust policy for 3 PGO service accounts |
| `aws_iam_role_policy` (secrets_ssm) | Inline policy for Secrets Manager + SSM parameter access |
| `aws_iam_role_policy` (s3_backup) | Inline policy for pgbackrest S3 backup bucket |

## Project Structure

```
psql/
├── terragrunt.hcl                          # Root config
├── _envcommon/
│   └── psql.hcl                            # Shared component config
├── modules/
│   └── psql/
│       ├── main.tf                         # Terraform resources
│       ├── variables.tf                    # Module input variables
│       └── outputs.tf                      # Module outputs
├── envs/
│   ├── systest/
│   │   ├── env.hcl
│   │   └── eu-west-1/psql/terragrunt.hcl
│   └── prodire/
│       ├── env.hcl
│       ├── eu-west-1/psql/terragrunt.hcl
│       └── af-south-1/psql/terragrunt.hcl
├── scripts/
│   └── generate_account_dirs.sh
├── .gitignore
└── README.md
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI** v2 (for `generate_account_dirs.sh`)
- An EKS cluster with OIDC provider
- S3 bucket `postgres-operator-<env>-backups-<account_id>` must exist

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier |
| `service` | `string` | Service identifier (always `psql`) |
| `environment` | `string` | Environment name |
| `account_id` | `string` | Default AWS account ID |
| `eks_oidc_provider_arn` | `string` | ARN of the EKS cluster OIDC provider |
| `eks_oidc_provider_url` | `string` | URL of the EKS cluster OIDC provider |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"psql"` | Service identifier |
| `role_name` | `string` | `"psql"` | Role name for resource naming |
| `aws_region` | `string` | - | AWS region |
| `eks_oidc_provider_arn` | `string` | - | EKS OIDC provider ARN |
| `eks_oidc_provider_url` | `string` | - | EKS OIDC provider URL |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `iam_role_arn` | ARN of the PGO service IAM role |
| `iam_role_name` | Name of the IAM role |
| `psql_cluster_name` | PGO cluster name used in SA naming |
| `backup_bucket_name` | S3 backup bucket name |
| `service_account_names` | List of K8s service account names |
| `service_account_namespace` | K8s namespace |

## Deployment

### Single Account

```bash
cd envs/systest/eu-west-1/psql
terragrunt plan && terragrunt apply
```

### Multi-Account

```bash
./scripts/generate_account_dirs.sh prodire
cd envs/prodire && terragrunt run-all plan
```

## Remote State Layout

```
Bucket: <project>-<environment>-tfstate-<account_id>
Key:    psql/<region>/terraform.tfstate
```

## Porting Notes (CloudFormation to Terraform)

| CloudFormation | Terraform |
|----------------|-----------|
| `AWS::IAM::Role` with inline JSON trust (3 SAs) | `aws_iam_role` with `jsonencode` and list condition |
| `Fn::ImportValue` for EKS OIDC | Explicit variables |
| Single inline policy (SSM + S3) | Separate policies per concern |
| `PSQLClusterName` parameter | Computed `local.psql_cluster_name` |

### Key Improvements Over Original

- **Separate IAM policies** per concern for better auditability
- **Computed PSQL cluster name** from project/environment convention
- **Backup bucket name** derived automatically from convention
- **Multi-account/region support** via Terragrunt
