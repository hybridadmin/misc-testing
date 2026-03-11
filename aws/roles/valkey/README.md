# Valkey IAM Roles - Terraform Module

Terragrunt-managed Terraform module for provisioning IAM roles for Valkey
(Redis-compatible) containers on EKS. Creates one IAM role per Valkey instance,
each with IRSA trust policy and SSM/Secrets Manager access.

**Ported from:** Ansible + CloudFormation (`roles/valkey/files/template.json`)

## Architecture

```
                     ┌──────────────────────────────────────────┐
                     │              AWS Account                 │
                     │                                          │
                     │  for each valkey instance:               │
                     │  ┌────────────────────────────────────┐  │
                     │  │        IAM Role (IRSA)             │  │
                     │  │                                    │  │
                     │  │  Trust: EKS OIDC Provider          │  │
                     │  │  SA: <proj>-<env>-<inst>-valkey-sa │  │
                     │  │                                    │  │
                     │  │  Policies:                         │  │
                     │  │   ├── Secrets Manager (GetSecret)  │  │
                     │  │   └── SSM Parameters (Get/List)    │  │
                     │  └────────────────────────────────────┘  │
                     └──────────────────────────────────────────┘
```

## Resources Created (per Valkey instance)

| Resource | Description |
|----------|-------------|
| `aws_iam_role` | IAM role with OIDC trust policy for the Valkey service account |
| `aws_iam_role_policy` (secrets_ssm) | Inline policy for Secrets Manager + SSM parameter access |

## Project Structure

```
valkey/
├── terragrunt.hcl                          # Root config
├── _envcommon/
│   └── valkey.hcl                          # Shared component config
├── modules/
│   └── valkey/
│       ├── main.tf                         # Terraform resources
│       ├── variables.tf                    # Module input variables
│       └── outputs.tf                      # Module outputs
├── envs/
│   ├── systest/
│   │   ├── env.hcl
│   │   └── eu-west-1/valkey/terragrunt.hcl
│   └── prodire/
│       ├── env.hcl
│       ├── eu-west-1/valkey/terragrunt.hcl
│       └── af-south-1/valkey/terragrunt.hcl
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

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier |
| `service` | `string` | Service identifier (always `valkey`) |
| `environment` | `string` | Environment name |
| `account_id` | `string` | Default AWS account ID |
| `eks_oidc_provider_arn` | `string` | ARN of the EKS cluster OIDC provider |
| `eks_oidc_provider_url` | `string` | URL of the EKS cluster OIDC provider |
| `valkey_instances` | `list(string)` | Names of Valkey instances to create roles for |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"valkey"` | Service identifier |
| `role_name` | `string` | `"valkey"` | Role name for resource naming |
| `aws_region` | `string` | - | AWS region |
| `eks_oidc_provider_arn` | `string` | - | EKS OIDC provider ARN |
| `eks_oidc_provider_url` | `string` | - | EKS OIDC provider URL |
| `valkey_instances` | `list(string)` | `["default"]` | Instance names for IAM roles |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `iam_role_arns` | Map of instance name to IAM role ARN |
| `iam_role_names` | Map of instance name to IAM role name |
| `iam_role_ids` | Map of instance name to IAM role ID |
| `service_account_names` | Map of instance name to K8s SA name |
| `service_account_namespace` | K8s namespace |

### Multiple Valkey Instances

The original Ansible role iterated over a `valkey` dict to create a stack per
instance. This module replicates that behavior using `for_each`:

```hcl
# In env.hcl:
locals {
  valkey_instances = ["cache", "session", "queue"]
}
```

This creates three IAM roles:
- `DEVOPS-PRODIRE-CACHE-VALKEY-EKSServiceIamRole`
- `DEVOPS-PRODIRE-SESSION-VALKEY-EKSServiceIamRole`
- `DEVOPS-PRODIRE-QUEUE-VALKEY-EKSServiceIamRole`

Each bound to its respective service account:
- `devops-prodire-cache-valkey-sa`
- `devops-prodire-session-valkey-sa`
- `devops-prodire-queue-valkey-sa`

## Deployment

### Single Account

```bash
cd envs/systest/eu-west-1/valkey
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
Key:    valkey/<region>/terraform.tfstate
```

## Porting Notes (CloudFormation to Terraform)

| CloudFormation | Terraform |
|----------------|-----------|
| `AWS::IAM::Role` (one stack per valkey instance via Ansible loop) | `aws_iam_role.valkey` with `for_each` over `valkey_instances` |
| `LCSTACK` parameter (lower-case stack name) | Computed from `project-environment-instance-role_name` |
| `Fn::ImportValue` for EKS OIDC | Explicit variables |
| Ansible `dict2items` loop | Terraform `for_each` |

### Key Improvements Over Original

- **Single Terraform apply** creates all Valkey instance roles (no Ansible loop)
- **Map outputs** for easy programmatic access to role ARNs by instance name
- **Dynamic instance count** -- add/remove instances by editing `valkey_instances`
- **Multi-account/region support** via Terragrunt
