# Redis - ElastiCache Valkey Cluster Terraform Module

Terragrunt-managed Terraform module for deploying encrypted AWS ElastiCache
Valkey replication groups (clusters) across multiple accounts and regions.

Valkey is a Redis-compatible engine offering 20% lower node pricing and no
extended support fees compared to Redis OSS on ElastiCache.

## Architecture

```
                     ┌─────────────────────────────────────────────┐
                     │              AWS Account                    │
                     │                                             │
                     │  ┌──────────────────────────────────────┐   │
                     │  │           VPC                         │   │
                     │  │                                       │   │
                     │  │  ┌──────────┐  6379/tcp               │   │
                     │  │  │    SG    │◄──── (VPC CIDR)         │   │
                     │  │  └────┬─────┘                         │   │
                     │  │       │                                │   │
                     │  │  ┌────▼───────────────────────────┐   │   │
                     │  │  │  ElastiCache Replication Group  │   │   │
                     │  │  │                                 │   │   │
                     │  │  │  engine: valkey 7.2             │   │   │
                     │  │  │  encrypted: KMS (at rest)       │   │   │
                     │  │  │  encrypted: TLS (in transit)    │   │   │
                     │  │  │  multi-AZ + auto failover       │   │   │
                     │  │  │                                 │   │   │
                     │  │  │  ┌─────────────────────────┐   │   │   │
                     │  │  │  │   Node Groups (Shards)  │   │   │   │
                     │  │  │  │  ┌──────┐  ┌──────────┐ │   │   │   │
                     │  │  │  │  │Primary│  │ Replica  │ │   │   │   │
                     │  │  │  │  │ AZ-1  │  │  AZ-2    │ │   │   │   │
                     │  │  │  │  └──────┘  └──────────┘ │   │   │   │
                     │  │  │  └─────────────────────────┘   │   │   │
                     │  │  └────────────────────────────────┘   │   │
                     │  │                                       │   │
                     │  │  ┌────────────────────────────────┐   │   │
                     │  │  │  Subnet Group (private subnets) │   │   │
                     │  │  └────────────────────────────────┘   │   │
                     │  └──────────────────────────────────────┘   │
                     └─────────────────────────────────────────────┘
```

## Resources Created

| Resource | Description |
|----------|-------------|
| `aws_security_group` | Allows Valkey (TCP 6379) from VPC CIDR, all outbound |
| `aws_kms_key` + `aws_kms_alias` | Customer-managed key for at-rest encryption with key rotation enabled (optional — disabled to save cost) |
| `aws_elasticache_subnet_group` | Subnet group spanning private subnets |
| `aws_elasticache_parameter_group` | Valkey 7.x parameter group with optional overrides |
| `aws_elasticache_replication_group` | Valkey cluster with multi-AZ, auto failover, encryption in transit + at rest |

## Project Structure

```
redis/
├── terragrunt.hcl                    # Root config: remote state, provider, common inputs
├── _envcommon/
│   └── redis.hcl                     # Shared component config (module source, env inputs)
├── modules/
│   └── redis/
│       ├── main.tf                   # Terraform resources
│       ├── variables.tf              # Module input variables
│       └── outputs.tf                # Module outputs
├── envs/
│   ├── systest/                      # Single-account environment
│   │   ├── env.hcl                   # Environment variables
│   │   └── eu-west-1/
│   │       └── redis/
│   │           └── terragrunt.hcl    # Leaf deployment
│   └── prodire/                      # Multi-account environment
│       ├── env.hcl                   # Environment variables + target OUs/regions
│       ├── eu-west-1/
│       │   └── redis/
│       │       └── terragrunt.hcl    # Leaf deployment (default account)
│       └── af-south-1/
│           └── redis/
│               └── terragrunt.hcl    # Leaf deployment (default account)
├── scripts/
│   └── generate_account_dirs.sh      # OU account discovery + dir scaffolding
├── .gitignore
└── README.md
```

### Multi-Account Directory Layout (after running generate_account_dirs.sh)

```
envs/prodire/
├── env.hcl
├── eu-west-1/
│   ├── redis/
│   │   └── terragrunt.hcl           # Default account deployment
│   ├── 111111111111/
│   │   ├── account.hcl              # Account-specific overrides
│   │   └── redis/
│   │       └── terragrunt.hcl       # Per-account deployment
│   └── 222222222222/
│       ├── account.hcl
│       └── redis/
│           └── terragrunt.hcl
└── af-south-1/
    ├── redis/
    │   └── terragrunt.hcl
    ├── 111111111111/
    │   ├── account.hcl
    │   └── redis/
    │       └── terragrunt.hcl
    └── ...
```

## Prerequisites

- **Terraform** >= 1.5.0
- **Terragrunt** >= 0.50.0
- **AWS CLI** v2 (for `generate_account_dirs.sh`)
- **jq** (for `generate_account_dirs.sh`)
- An IAM role `<project>-terraform-execution` in each target account that Terragrunt can assume
- S3 bucket and DynamoDB table for remote state (per account)
- An existing VPC with private subnets in the target account/region

## Configuration

### Environment Variables (`env.hcl`)

| Variable | Type | Description |
|----------|------|-------------|
| `project` | `string` | Project identifier (e.g. `devops`) |
| `service` | `string` | Service identifier (always `redis`) |
| `environment` | `string` | Environment name (e.g. `systest`, `prodire`) |
| `account_id` | `string` | Default AWS account ID (overridden per-account in multi-account mode) |
| `vpc_id` | `string` | VPC ID where the cluster will be deployed |
| `vpc_cidr` | `string` | VPC CIDR block for security group ingress |
| `private_subnet_ids` | `list(string)` | Private subnet IDs for the subnet group (one per AZ) |
| `node_type` | `string` | ElastiCache node type (e.g. `cache.t4g.micro`, `cache.r7g.large`) |
| `engine_version` | `string` | Valkey engine version (e.g. `7.2`) |
| `num_shards` | `number` | Number of shards (node groups) |
| `replicas_per_shard` | `number` | Read replicas per shard |
| `snapshot_retention_limit` | `number` | Days to retain snapshots (0 to disable) |
| `use_custom_kms_key` | `bool` | Use customer-managed KMS key (`false` for free AWS-managed key) |

#### Multi-Account Only

| Variable | Type | Description |
|----------|------|-------------|
| `target_ou_ids` | `list(string)` | AWS Organizations OU IDs to enumerate accounts from |
| `target_regions` | `list(string)` | AWS regions to deploy into |

### Module Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project` | `string` | - | Project identifier |
| `environment` | `string` | - | Deployment environment |
| `service` | `string` | `"redis"` | Service identifier |
| `aws_region` | `string` | - | AWS region |
| `vpc_id` | `string` | - | VPC ID for security group |
| `vpc_cidr` | `string` | - | VPC CIDR for ingress |
| `private_subnet_ids` | `list(string)` | - | Subnet IDs for the subnet group |
| `node_type` | `string` | `"cache.t4g.micro"` | ElastiCache node instance type |
| `engine_version` | `string` | `"7.2"` | Valkey engine version |
| `parameter_family` | `string` | `"valkey7"` | Parameter group family (must match engine version) |
| `num_shards` | `number` | `1` | Number of node groups (shards) |
| `replicas_per_shard` | `number` | `1` | Read replicas per shard (>=1 for multi-AZ) |
| `parameters` | `list(object)` | `[]` | Valkey parameter overrides (`name`/`value` pairs) |
| `maintenance_window` | `string` | `"sun:03:00-sun:04:00"` | Weekly maintenance window (UTC) |
| `snapshot_window` | `string` | `"01:00-02:00"` | Daily snapshot window (UTC) |
| `snapshot_retention_limit` | `number` | `7` | Days to retain snapshots (0 to disable) |
| `apply_immediately` | `bool` | `false` | Apply changes immediately vs. next maintenance window |
| `use_custom_kms_key` | `bool` | `true` | Use customer-managed KMS key (set `false` to use free AWS-managed key) |
| `tags` | `map(string)` | `{}` | Additional tags |

### Module Outputs

| Output | Description |
|--------|-------------|
| `replication_group_id` | ElastiCache replication group ID |
| `replication_group_arn` | ElastiCache replication group ARN |
| `primary_endpoint_address` | Primary/configuration endpoint address |
| `reader_endpoint_address` | Reader endpoint address for read replicas |
| `port` | Valkey port (6379) |
| `security_group_id` | Security group ID |
| `kms_key_arn` | KMS key ARN for encryption (null when using AWS-managed key) |
| `kms_key_id` | KMS key ID for encryption (null when using AWS-managed key) |
| `subnet_group_name` | ElastiCache subnet group name |
| `parameter_group_name` | ElastiCache parameter group name |

## Deployment

### Single Account (systest)

```bash
# Plan
cd envs/systest/eu-west-1/redis
terragrunt plan

# Apply
terragrunt apply
```

### Single Region, All Accounts (prodire)

```bash
# Plan all deployments in eu-west-1
cd envs/prodire/eu-west-1
terragrunt run-all plan

# Apply all
terragrunt run-all apply
```

### All Regions, All Accounts

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

### Specific Account in Multi-Account Mode

```bash
cd envs/prodire/eu-west-1/111111111111/redis
terragrunt plan
terragrunt apply
```

## Multi-Account Setup

### 1. Configure Target OUs and Regions

Edit `envs/<environment>/env.hcl` and set the `target_ou_ids` and `target_regions`:

```hcl
locals {
  # ...
  target_ou_ids = [
    "ou-xxxx-aaaaaaaa", # Production Accounts OU
    "ou-xxxx-bbbbbbbb", # Development Accounts OU
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

This queries AWS Organizations for all active accounts in the target OUs and
creates the directory structure with `account.hcl` and leaf `terragrunt.hcl`
files for each account/region combination. Existing directories are skipped.

### 3. Customize Per-Account Settings

Each account will likely have its own VPC and potentially different cluster
sizing. Override in the generated leaf `terragrunt.hcl`:

```hcl
inputs = {
  vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
  vpc_cidr           = "10.1.0.0/16"
  private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
  node_type          = "cache.r7g.xlarge"
  num_shards         = 3
  replicas_per_shard = 2
}
```

### 4. Deploy

```bash
cd envs/prodire
terragrunt run-all plan
terragrunt run-all apply
```

## Cluster Sizing Guide

| Environment | `node_type` | `num_shards` | `replicas_per_shard` | Description |
|-------------|-------------|-------------|---------------------|-------------|
| Dev/Test (min cost) | `cache.t4g.micro` | 1 | 0 | Single node, no HA, lowest cost |
| Dev/Test (HA) | `cache.t4g.micro` | 1 | 1 | Minimal HA, low cost |
| Staging | `cache.r7g.large` | 1 | 1 | Production-like, single shard |
| Production | `cache.r7g.large` | 2-3 | 1-2 | Multi-shard for throughput |
| High-traffic | `cache.r7g.xlarge` | 3+ | 2 | Maximum throughput & HA |

### Cluster Mode Behavior

- **`num_shards = 1`**: Single shard replication group. Data is not partitioned.
  Use `primary_endpoint_address` for read/write operations.
- **`num_shards > 1`**: Cluster mode enabled. Data is hash-slot partitioned
  across shards. Use `primary_endpoint_address` (configuration endpoint) with
  a cluster-aware client.

### Automatic Failover

Automatic failover and multi-AZ are enabled when `replicas_per_shard >= 1`.
When set to `0` with a single shard, the cluster runs as a standalone primary
with no failover capability.

## Cost Optimization

The following settings can be tuned per-environment to reduce cost for
non-production clusters:

| Setting | Default | Cost-saving value | Saving |
|---------|---------|-------------------|--------|
| `replicas_per_shard` | `1` (2 nodes) | `0` (1 node) | ~50% compute cost |
| `snapshot_retention_limit` | `7` | `0` (disabled) | Snapshot storage eliminated |
| `use_custom_kms_key` | `true` ($1/mo) | `false` (AWS-managed, free) | ~$1/month |

Additionally, Valkey provides 20% lower node pricing compared to Redis OSS
on ElastiCache, with no extended support fees.

When `replicas_per_shard = 0`, automatic failover and multi-AZ are
automatically disabled (single standalone primary). This is suitable for
dev/test workloads where availability is not critical.

The systest environment is pre-configured with cost-saving options:

```hcl
# envs/systest/env.hcl
replicas_per_shard      = 0      # Single node
snapshot_retention_limit = 1      # 1 day of snapshots
use_custom_kms_key      = false   # AWS-managed KMS key
```

## Custom Parameters

Override Valkey configuration via the `parameters` variable:

```hcl
# In env.hcl or leaf terragrunt.hcl inputs:
parameters = [
  { name = "maxmemory-policy", value = "allkeys-lru" },
  { name = "notify-keyspace-events", value = "Ex" },
  { name = "timeout", value = "300" },
]
```

## Remote State Layout

State is stored per-account in S3:

```
Bucket: <project>-<environment>-tfstate-<account_id>
Key:    redis/<region>/terraform.tfstate
Lock:   <project>-<environment>-tfstate-lock (DynamoDB)
```

Example:
```
Bucket: devops-prodire-tfstate-111111111111
Key:    redis/eu-west-1/terraform.tfstate
```

## IAM Permissions Required

The `<project>-terraform-execution` role assumed by Terragrunt needs:

| Service | Actions |
|---------|---------|
| ElastiCache | `elasticache:*` |
| EC2 | `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress`, `ec2:DescribeSecurityGroups`, `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:CreateTags`, `ec2:DeleteTags` |
| KMS | `kms:CreateKey`, `kms:CreateAlias`, `kms:DeleteAlias`, `kms:DescribeKey`, `kms:EnableKeyRotation`, `kms:GetKeyPolicy`, `kms:GetKeyRotationStatus`, `kms:ListAliases`, `kms:PutKeyPolicy`, `kms:ScheduleKeyDeletion`, `kms:TagResource`, `kms:UntagResource` |
| S3 | Read/write to the tfstate bucket |
| DynamoDB | Read/write to the tfstate-lock table |

For `generate_account_dirs.sh`, the caller needs:

| Service | Actions |
|---------|---------|
| Organizations | `organizations:ListAccountsForParent` |

## Adding a New Environment

1. Create the environment directory:
   ```bash
   mkdir -p envs/<new-env>/
   ```

2. Create `envs/<new-env>/env.hcl` with environment-specific variables (use
   `envs/systest/env.hcl` as a template for single-account, or
   `envs/prodire/env.hcl` for multi-account).

3. Create region/component directories:
   ```bash
   mkdir -p envs/<new-env>/<region>/redis
   ```

4. Create a leaf `terragrunt.hcl` (copy from an existing environment).

5. For multi-account, run the scaffolding script:
   ```bash
   ./scripts/generate_account_dirs.sh <new-env>
   ```

## Adding a New Region

1. Add the region to `target_regions` in `env.hcl` (for documentation and
   script usage).

2. Create the region directory:
   ```bash
   mkdir -p envs/<env>/<new-region>/redis
   ```

3. Copy or create a leaf `terragrunt.hcl`.

4. For multi-account, re-run the scaffolding script -- it skips existing
   directories and only creates new ones:
   ```bash
   ./scripts/generate_account_dirs.sh <env>
   ```

## Connecting to the Cluster

Since transit encryption (TLS) is enabled, clients must connect using TLS.
Valkey is wire-compatible with Redis, so existing Redis clients work unchanged:

```bash
# Using valkey-cli or redis-cli with TLS
valkey-cli --tls -h <primary_endpoint_address> -p 6379
redis-cli --tls -h <primary_endpoint_address> -p 6379
```

For cluster-mode (`num_shards > 1`), use a cluster-aware client:

```python
# Python example with redis-py (works with Valkey)
import redis
rc = redis.RedisCluster(
    host="<primary_endpoint_address>",
    port=6379,
    ssl=True,
    decode_responses=True,
)
```
