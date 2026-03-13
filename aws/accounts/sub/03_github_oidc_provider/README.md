# GitHub OIDC - Multi-Account AWS IAM OIDC Provider for GitHub Actions

Deploys an AWS IAM OIDC Identity Provider for GitHub Actions and associated IAM roles across multiple AWS accounts and regions via Terragrunt. This eliminates the need for long-lived AWS access keys in GitHub Actions CI/CD pipelines.

## What It Does

- Creates an **IAM OIDC Identity Provider** in each target AWS account that trusts GitHub's OIDC token issuer (`token.actions.githubusercontent.com`)
- Creates **IAM Roles** with trust policies scoped to specific GitHub organisations, repositories, and branches
- Attaches **managed and inline IAM policies** to those roles for fine-grained permissions
- Deploys across **multiple AWS accounts** (discovered from AWS Organizations OUs) and **multiple regions**

## Directory Structure

```
githuboidc/
├── README.md                                          # This file
├── .gitignore
├── terragrunt.hcl                                     # Root Terragrunt config (provider, backend, common inputs)
├── _envcommon/
│   └── github-oidc.hcl                                # Shared component config (module source, common inputs)
├── modules/
│   └── github-oidc/
│       ├── main.tf                                    # Terraform resources (OIDC provider, IAM roles, policies)
│       ├── variables.tf                               # Input variables
│       └── outputs.tf                                 # Outputs (provider ARN, role ARNs/names)
├── envs/
│   ├── prodire/                                       # Production Ireland environment (multi-account)
│   │   ├── env.hcl                                    # Environment variables, target OUs, regions, role definitions
│   │   ├── eu-west-1/
│   │   │   └── github-oidc/
│   │   │       └── terragrunt.hcl                     # Leaf deployment
│   │   └── af-south-1/
│   │       └── github-oidc/
│   │           └── terragrunt.hcl                     # Leaf deployment
│   └── systest/                                       # System test environment (single-account)
│       ├── env.hcl                                    # Environment variables, role definitions
│       └── eu-west-1/
│           └── github-oidc/
│               └── terragrunt.hcl                     # Leaf deployment
└── scripts/
    └── generate_account_dirs.sh                       # Auto-generates per-account directories from AWS Organizations OUs
```

### Multi-Account Layout (after running generate_account_dirs.sh)

For multi-account environments, the script creates per-account directories:

```
envs/prodire/eu-west-1/
├── github-oidc/terragrunt.hcl                         # Single-account deployment (uses env.hcl account_id)
├── 111111111111/                                      # Per-account deployment
│   ├── account.hcl                                    # Account-specific overrides
│   └── github-oidc/
│       └── terragrunt.hcl                             # Leaf deployment for this account
└── 222222222222/
    ├── account.hcl
    └── github-oidc/
        └── terragrunt.hcl
```

## Architecture Patterns

### Three-Layer Include Hierarchy

Every leaf `terragrunt.hcl` includes two parent configs:

1. **Root `terragrunt.hcl`** - Provides: S3 remote state, AWS provider with assume-role, provider version constraints, common inputs (`project`, `environment`, `service`, `aws_region`)
2. **`_envcommon/github-oidc.hcl`** - Provides: Terraform module source path, component-specific inputs (`github_actions_roles`)

Leaf files are minimal pointers (~14 lines) that inherit everything from the hierarchy.

### Path-Based Configuration

Environment and region are **extracted from the directory path** via regex:

```
envs/<environment>/<region>/github-oidc/terragrunt.hcl
```

No need to set region or environment explicitly in leaf configs.

### Optional Per-Account Override

The root config uses `try()` to optionally load `account.hcl`:

- **Single-account envs** (e.g. `systest`): `account_id` comes from `env.hcl`
- **Multi-account envs** (e.g. `prodire`): Each `<account_id>/account.hcl` overrides the account_id

### State Isolation

Each account gets its own S3 state bucket and state key:

- **Bucket**: `<project>-<environment>-tfstate-<account_id>`
- **Key**: `<service>/<region>/terraform.tfstate`
- **Lock table**: `<project>-<environment>-tfstate-lock`

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI v2** (for the account generation script)
- **jq** (for the account generation script)
- AWS credentials with:
  - `sts:AssumeRole` to the `<project>-terraform-execution` role in each target account
  - `organizations:ListAccountsForParent` permission (for the generation script)
- Pre-existing S3 buckets and DynamoDB table for remote state in each target account

## Configuration

### Environment Variables (`env.hcl`)

Each environment's `env.hcl` defines:

| Variable | Description |
|----------|-------------|
| `project` | Project identifier (e.g. `devops`) |
| `service` | Service name (fixed: `github-oidc`) |
| `environment` | Environment name (e.g. `prodire`, `systest`) |
| `account_id` | Default AWS account ID (overridden per-account in multi-account setups) |
| `github_actions_roles` | List of IAM role definitions (see below) |
| `target_ou_ids` | AWS Organizations OU IDs for multi-account discovery |
| `target_regions` | AWS regions to deploy into |

### GitHub Actions Role Definition

Each entry in `github_actions_roles` supports:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Role name suffix (prepended with `PROJECT-ENVIRONMENT-`) |
| `description` | No | Role description |
| `subject_claims` | Yes | List of GitHub OIDC subject claim patterns |
| `managed_policy_arns` | No | List of managed IAM policy ARNs to attach |
| `inline_policies` | No | List of `{name, policy}` inline policy objects |
| `max_session_duration` | No | Max session duration in seconds (default: 3600) |

### Subject Claim Patterns

The `subject_claims` field controls which GitHub Actions workflows can assume the role. Patterns follow the format:

```
repo:<owner>/<repo>:<filter>
```

Examples:

| Pattern | Allows |
|---------|--------|
| `repo:my-org/my-repo:ref:refs/heads/main` | Only the `main` branch |
| `repo:my-org/my-repo:ref:refs/heads/release/*` | Any `release/*` branch |
| `repo:my-org/my-repo:ref:refs/tags/v*` | Any tag starting with `v` |
| `repo:my-org/my-repo:pull_request` | Pull request workflows |
| `repo:my-org/my-repo:environment:production` | The `production` GitHub environment |
| `repo:my-org/*:ref:refs/heads/main` | `main` branch of any repo in the org |

## Usage

### 1. Single-Account Deployment (e.g. systest)

```bash
# Plan
cd envs/systest/eu-west-1/github-oidc
terragrunt plan

# Apply
terragrunt apply
```

### 2. Multi-Account Deployment

#### Generate account directories from AWS Organizations

```bash
# Discover accounts in the target OUs and scaffold directories
./scripts/generate_account_dirs.sh prodire
```

This queries AWS Organizations for all active accounts in the OUs defined in `envs/prodire/env.hcl` and creates the per-account directory structure.

#### Deploy all accounts in an environment

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

#### Deploy a single account/region

```bash
cd envs/prodire/eu-west-1/111111111111/github-oidc
terragrunt plan
terragrunt apply
```

### 3. Using the Role in GitHub Actions

Once deployed, configure your GitHub Actions workflow to assume the role:

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  id-token: write   # Required for OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111111111111:role/DEVOPS-PRODIRE-github-actions-deploy
          aws-region: eu-west-1

      - name: Verify identity
        run: aws sts get-caller-identity
```

Key points:
- The workflow must have `permissions.id-token: write` to request an OIDC token
- The `role-to-assume` ARN follows the pattern `arn:aws:iam::<account_id>:role/<PROJECT>-<ENVIRONMENT>-<role_name>`
- No AWS access keys are stored as GitHub secrets

## Terraform Module Inputs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"github-oidc"` | Service name |
| `aws_region` | `string` | - | AWS region |
| `oidc_client_ids` | `list(string)` | `["sts.amazonaws.com"]` | OIDC provider audience list |
| `github_actions_roles` | `list(object)` | `[]` | IAM role definitions (see above) |
| `tags` | `map(string)` | `{}` | Additional tags |

## Terraform Module Outputs

| Output | Description |
|--------|-------------|
| `oidc_provider_arn` | ARN of the IAM OIDC Identity Provider |
| `oidc_provider_url` | URL of the IAM OIDC Identity Provider |
| `role_arns` | Map of role name to ARN |
| `role_names` | Map of role name to full IAM role name |

## Adding a New Environment

1. Create the environment directory and `env.hcl`:

```bash
mkdir -p envs/newenv
```

2. Create `envs/newenv/env.hcl` with your configuration (copy from an existing env and modify)

3. For single-account deployment, create region directories manually:

```bash
mkdir -p envs/newenv/eu-west-1/github-oidc
```

And add a leaf `terragrunt.hcl` with the standard includes.

4. For multi-account deployment, add `target_ou_ids` and `target_regions` to your `env.hcl`, then run:

```bash
./scripts/generate_account_dirs.sh newenv
```

## Adding a New Role

Edit the `github_actions_roles` list in the relevant `env.hcl` file:

```hcl
github_actions_roles = [
  # ... existing roles ...
  {
    name        = "github-actions-terraform"
    description = "GitHub Actions role for Terraform deployments"
    subject_claims = [
      "repo:my-org/infra-repo:ref:refs/heads/main",
    ]
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/PowerUserAccess",
    ]
  },
]
```

Then run `terragrunt plan` and `terragrunt apply` in the affected leaf directories (or `terragrunt run-all apply` from the environment root).

## Important Notes

- **IAM is global**: The OIDC provider and IAM roles are global resources in AWS. Deploying to multiple regions in the same account will cause conflicts. For most use cases, deploy to a single region per account. If you need region-specific deployments, the module will work but be aware each region will create its own OIDC provider.
- **Thumbprint rotation**: The module fetches GitHub's TLS certificate thumbprint dynamically via the `tls_certificate` data source. AWS also validates tokens cryptographically, so the thumbprint is a secondary verification.
- **One OIDC provider per account**: AWS allows only one OIDC provider per unique URL per account. If you already have a GitHub OIDC provider in an account, you will need to import it: `terragrunt import aws_iam_openid_connect_provider.github <arn>`.
