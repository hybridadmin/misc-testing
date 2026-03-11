# EKS Service IAM Role - Terraform Module

Terragrunt-managed Terraform module for provisioning IAM roles with IRSA
(IAM Roles for Service Accounts) trust policies for EKS workloads. Includes
policies for Secrets Manager, SSM Parameter Store, SSM Agent, and S3 access.

**Ported from:** Ansible + CloudFormation (`roles/eksservice/files/template.json`)

## Architecture

```
                     ┌──────────────────────────────────────────┐
                     │              AWS Account                 │
                     │                                          │
                     │  ┌────────────────────────────────────┐  │
                     │  │        IAM Role (IRSA)             │  │
                     │  │                                    │  │
                     │  │  Trust: EKS OIDC Provider          │  │
                     │  │  SA:    <project>-<env>-<svc>-sa   │  │
                     │  │                                    │  │
                     │  │  Policies:                         │  │
                     │  │   ├── Secrets Manager (GetSecret)  │  │
                     │  │   ├── SSM Parameters (Get/List)    │  │
                     │  │   ├── SSM Agent (messaging)        │  │
                     │  │   ├── S3 Project Bucket (full)     │  │
                     │  │   └── S3 Extra Buckets (full)      │  │
                     │  │       (one policy per bucket)      │  │
                     │  └────────────────────────────────────┘  │
                     └──────────────────────────────────────────┘
```

## Resources Created

| Resource | Description |
|----------|-------------|
| `aws_iam_role` | IAM role with OIDC trust policy for EKS service account |
| `aws_iam_role_policy` (secrets_ssm) | Inline policy for Secrets Manager + SSM parameter access |
| `aws_iam_role_policy` (ssm_agent) | Inline policy for SSM Agent messaging channels |
| `aws_iam_role_policy` (project_s3) | Inline policy for project S3 bucket access |
| `aws_iam_role_policy` (extra_s3) | Dynamic policies for each additional S3 bucket |

## Project Structure

```
eksservice/
├── terragrunt.hcl                          # Root config: remote state, provider, common inputs
├── _envcommon/
│   └── eksservice.hcl                      # Shared component config (module source, env inputs)
├── modules/
│   └── eksservice/
│       ├── main.tf                         # Terraform resources
│       ├── variables.tf                    # Module input variables
│       └── outputs.tf                      # Module outputs
├── envs/
│   ├── systest/                            # Single-account environment
│   │   ├── env.hcl                         # Environment variables
│   │   └── eu-west-1/
│   │       └── eksservice/
│   │           └── terragrunt.hcl          # Leaf deployment
│   └── prodire/                            # Multi-account environment
│       ├── env.hcl                         # Environment variables + target OUs/regions
│       ├── eu-west-1/
│       │   └── eksservice/
│       │       └── terragrunt.hcl          # Leaf deployment
│       └── af-south-1/
│           └── eksservice/
│               └── terragrunt.hcl          # Leaf deployment
├── scripts/
│   └── generate_account_dirs.sh            # OU account discovery + dir scaffolding
├── .gitignore
└── README.md
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI** v2 (for `generate_account_dirs.sh`)
- **jq** (for `generate_account_dirs.sh`)
- An IAM role `<project>-terraform-execution` in each target account
- S3 bucket and DynamoDB table for remote state (per account)
- An EKS cluster with an OIDC provider configured

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier (e.g. `devops`) |
| `service` | `string` | Service name for the EKS workload |
| `environment` | `string` | Environment name (e.g. `systest`, `prodire`) |
| `account_id` | `string` | Default AWS account ID |
| `eks_oidc_provider_arn` | `string` | ARN of the EKS cluster OIDC provider |
| `eks_oidc_provider_url` | `string` | URL of the EKS cluster OIDC provider |
| `s3_buckets` | `list(string)` | Additional S3 bucket names to grant access to |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | - | Service name for the EKS workload |
| `aws_region` | `string` | - | AWS region |
| `eks_oidc_provider_arn` | `string` | - | EKS OIDC provider ARN |
| `eks_oidc_provider_url` | `string` | - | EKS OIDC provider URL |
| `s3_buckets` | `list(string)` | `[]` | Additional S3 bucket names |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `iam_role_arn` | ARN of the EKS service IAM role |
| `iam_role_name` | Name of the IAM role |
| `iam_role_id` | ID of the IAM role |
| `service_account_name` | K8s service account name the role is bound to |
| `service_account_namespace` | K8s namespace for the service account |

## Deployment

### Single Account (systest)

```bash
cd envs/systest/eu-west-1/eksservice
terragrunt plan
terragrunt apply
```

### All Regions, All Accounts (prodire)

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

## Multi-Account Setup

### 1. Configure Target OUs and Regions in `env.hcl`

```hcl
locals {
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa",
    "ou-xxxx-bbbbbbbb",
  ]
  target_regions = [
    "eu-west-1",
    "af-south-1",
  ]
}
```

### 2. Generate Account Directories

```bash
./scripts/generate_account_dirs.sh prodire
```

### 3. Deploy

```bash
cd envs/prodire && terragrunt run-all plan
```

## Remote State Layout

```
Bucket: <project>-<environment>-tfstate-<account_id>
Key:    eksservice/<region>/terraform.tfstate
Lock:   <project>-<environment>-tfstate-lock (DynamoDB)
```

## IAM Permissions Required

The `<project>-terraform-execution` role needs:

| Service | Actions |
|---------|---------|
| IAM | `iam:CreateRole`, `iam:DeleteRole`, `iam:GetRole`, `iam:PassRole`, `iam:TagRole`, `iam:UntagRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:GetRolePolicy`, `iam:ListRolePolicies`, `iam:ListAttachedRolePolicies` |
| S3 | Read/write to the tfstate bucket |
| DynamoDB | Read/write to the tfstate-lock table |

## Porting Notes (CloudFormation to Terraform)

| CloudFormation | Terraform |
|----------------|-----------|
| `AWS::IAM::Role` with inline JSON trust policy | `aws_iam_role.eks_service` with `jsonencode` |
| `Fn::ImportValue` for EKS OIDC provider | Explicit `eks_oidc_provider_arn` / `eks_oidc_provider_url` variables |
| `AWS::LanguageExtensions` + `Fn::ForEach::s3bucketlist` | `aws_iam_role_policy.extra_s3` with `for_each` |
| Single inline policy with all statements | Separate `aws_iam_role_policy` per concern (secrets, ssm agent, s3) |
| Stack parameters (PROJECT, Service, CLUSTER, etc.) | Terraform variables + data sources |

### Key Improvements Over Original

- **Separated IAM policies** by concern for better auditability
- **Dynamic S3 bucket policies** using native `for_each` (no CloudFormation transform needed)
- **No cross-stack references** -- OIDC provider details passed as explicit variables
- **Multi-account support** via Terragrunt directory structure
- **Multi-region support** via region-based leaf directories
